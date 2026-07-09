import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── AgOS Push provider (ARS-141 / C3, EngSpec §6) ───────────────────────────────
// Единственная обёртка отправки native-push. Notification Worker (ARS-142) зовёт эту
// функцию с channel='push'; она сама разрешает активные токены пользователя из
// public.push_token (ARS-139), шлёт через FCM v1 (android/web) и APNs (ios), ретраит
// транзиентные ошибки и деактивирует «мёртвые» токены (is_active=false).
//
// Все провайдеры env-guarded: без ключей — тихий skip (как WhatsApp в worker'е),
// чтобы функцию можно было деплоить до подключения FCM/APNs аккаунтов.
//
// Инвариант антимонополии/анонимности НЕ здесь: тексты приходят готовыми из C5
// (ARS-143) — provider ничего не дорисовывает про контрагента (D-M6-5/12).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// FCM HTTP v1 (не legacy): сервисный аккаунт Firebase.
const FCM_SERVICE_ACCOUNT_JSON = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON") ?? "";
const FCM_PROJECT_ID = Deno.env.get("FCM_PROJECT_ID") ?? "";

// APNs token-based auth (.p8 key).
const APNS_KEY = Deno.env.get("APNS_KEY") ?? ""; // PEM PKCS8 (-----BEGIN PRIVATE KEY-----)
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "";
const APNS_HOST = Deno.env.get("APNS_HOST") ?? "https://api.push.apple.com";

const MAX_RETRIES = 1; // один повтор на транзиентную (5xx/сеть) ошибку

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ── crypto helpers ──────────────────────────────────────────────────────────────
function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlStr(s: string): string {
  return b64url(new TextEncoder().encode(s));
}

// PEM (PKCS8) → ArrayBuffer с DER.
function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const buf = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i);
  return buf.buffer;
}

// ── FCM HTTP v1 ─────────────────────────────────────────────────────────────────
// OAuth2 access token из сервисного аккаунта (RS256 JWT → token endpoint).
let _fcmToken: { value: string; exp: number } | null = null;

async function getFcmAccessToken(): Promise<string | null> {
  if (!FCM_SERVICE_ACCOUNT_JSON || !FCM_PROJECT_ID) return null;
  const now = Math.floor(Date.now() / 1000);
  if (_fcmToken && _fcmToken.exp - 60 > now) return _fcmToken.value;

  let sa: { client_email: string; private_key: string };
  try {
    sa = JSON.parse(FCM_SERVICE_ACCOUNT_JSON);
  } catch {
    console.error("push-send: FCM_SERVICE_ACCOUNT_JSON is not valid JSON");
    return null;
  }

  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const signingInput = `${b64urlStr(JSON.stringify(header))}.${b64urlStr(
    JSON.stringify(claims)
  )}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(signingInput)
    )
  );
  const jwt = `${signingInput}.${b64url(sig)}`;

  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!resp.ok) {
    console.error("push-send: FCM token endpoint error", resp.status);
    return null;
  }
  const data = await resp.json();
  _fcmToken = { value: data.access_token, exp: now + (data.expires_in ?? 3600) };
  return _fcmToken.value;
}

// Возврат: 'ok' | 'dead' (токен невалиден → деактивировать) | 'retry' | 'error'.
async function sendFcm(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>
): Promise<"ok" | "dead" | "retry" | "error"> {
  const access = await getFcmAccessToken();
  if (!access) return "error"; // не сконфигурирован → skip выше

  const resp = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${access}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          data, // deep-link path из C5 доезжает до pushNotificationActionPerformed
        },
      }),
    }
  );

  if (resp.ok) return "ok";
  if (resp.status >= 500) return "retry";
  // 404 UNREGISTERED / 400 INVALID_ARGUMENT по токену = мёртвый токен.
  const txt = await resp.text();
  if (
    resp.status === 404 ||
    /UNREGISTERED|INVALID_ARGUMENT|registration-token-not-registered/i.test(txt)
  ) {
    return "dead";
  }
  console.error("push-send: FCM error", resp.status, txt.slice(0, 300));
  return "error";
}

// ── APNs (token-based) ───────────────────────────────────────────────────────────
let _apnsJwt: { value: string; iat: number } | null = null;

async function getApnsJwt(): Promise<string | null> {
  if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) return null;
  const now = Math.floor(Date.now() / 1000);
  // APNs требует свежий JWT не старше 1ч; переиспользуем ≤ 50 мин.
  if (_apnsJwt && now - _apnsJwt.iat < 3000) return _apnsJwt.value;

  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const claims = { iss: APNS_TEAM_ID, iat: now };
  const signingInput = `${b64urlStr(JSON.stringify(header))}.${b64urlStr(
    JSON.stringify(claims)
  )}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(APNS_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(signingInput)
    )
  );
  _apnsJwt = { value: `${signingInput}.${b64url(sig)}`, iat: now };
  return _apnsJwt.value;
}

async function sendApns(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>
): Promise<"ok" | "dead" | "retry" | "error"> {
  const jwt = await getApnsJwt();
  if (!jwt || !APNS_BUNDLE_ID) return "error";

  const resp = await fetch(`${APNS_HOST}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
    },
    body: JSON.stringify({
      aps: { alert: { title, body }, sound: "default" },
      ...data, // custom keys (path) на верхнем уровне payload
    }),
  });

  if (resp.ok) return "ok";
  if (resp.status >= 500) return "retry";
  // 410 = устройство больше не активно; 400 BadDeviceToken/DeviceTokenNotForTopic.
  const txt = await resp.text();
  if (resp.status === 410 || /BadDeviceToken|Unregistered/i.test(txt)) return "dead";
  console.error("push-send: APNs error", resp.status, txt.slice(0, 300));
  return "error";
}

async function sendWithRetry(
  fn: () => Promise<"ok" | "dead" | "retry" | "error">
): Promise<"ok" | "dead" | "error"> {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    let r: "ok" | "dead" | "retry" | "error";
    try {
      r = await fn();
    } catch (e) {
      console.error("push-send: transport error", e);
      r = "retry";
    }
    if (r !== "retry") return r;
    if (attempt < MAX_RETRIES) await new Promise((res) => setTimeout(res, 500));
  }
  return "error";
}

// ── Main handler ──────────────────────────────────────────────────────────────
interface PushRequest {
  user_id: string;
  title: string;
  body: string;
  data?: Record<string, string>;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  let payload: PushRequest;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const { user_id, title, body, data = {} } = payload;
  if (!user_id || !title || !body) {
    return json({ error: "user_id, title, body required" }, 400);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Активные токены пользователя (ARS-139). service_role → минуя RLS.
  const { data: tokens, error } = await supabase
    .from("push_token")
    .select("id, token, platform")
    .eq("user_id", user_id)
    .eq("is_active", true);

  if (error) {
    console.error("push-send: token lookup failed", error.message);
    return json({ error: "token lookup failed" }, 500);
  }
  if (!tokens || tokens.length === 0) {
    return json({ sent: 0, failed: 0, deactivated: 0, skipped: 0 });
  }

  const dataStr: Record<string, string> = {};
  for (const [k, v] of Object.entries(data)) dataStr[k] = String(v);

  let sent = 0;
  let failed = 0;
  let deactivated = 0;
  let skipped = 0;
  const deadIds: string[] = [];

  for (const t of tokens) {
    const useApns = t.platform === "ios";
    const configured = useApns
      ? !!(APNS_KEY && APNS_KEY_ID && APNS_TEAM_ID && APNS_BUNDLE_ID)
      : !!(FCM_SERVICE_ACCOUNT_JSON && FCM_PROJECT_ID);
    if (!configured) {
      skipped++;
      continue;
    }

    const result = await sendWithRetry(() =>
      useApns
        ? sendApns(t.token, title, body, dataStr)
        : sendFcm(t.token, title, body, dataStr)
    );

    if (result === "ok") sent++;
    else if (result === "dead") {
      deadIds.push(t.id);
      deactivated++;
    } else failed++;
  }

  // Чистка мёртвых токенов: is_active=false (не delete — сохраняем историю, is_active-soft).
  if (deadIds.length > 0) {
    const { error: deErr } = await supabase
      .from("push_token")
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .in("id", deadIds);
    if (deErr) console.error("push-send: dead-token cleanup failed", deErr.message);
  }

  return json({ sent, failed, deactivated, skipped });
});

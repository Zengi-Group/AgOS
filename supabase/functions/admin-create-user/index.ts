import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// admin-create-user — создаёт нового пользователя в Supabase Auth с паролем.
// Триггер trg_on_auth_user_created (d01_kernel.sql) автоматически заводит
// строку в public.users. Доступ только админу: проверяем JWT вызывающего
// через RPC fn_is_admin(), привилегированную операцию делаем service-role клиентом.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  // ── Проверка: вызывающий — админ ──────────────────────────────────────────
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader) return json({ error: "Не авторизован" }, 401);

  const supabaseAuthed = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: isAdmin, error: adminErr } = await supabaseAuthed.rpc("fn_is_admin");
  if (adminErr) return json({ error: adminErr.message }, 500);
  if (!isAdmin) return json({ error: "Доступ только для администратора" }, 403);

  // ── Вход ──────────────────────────────────────────────────────────────────
  let body: Record<string, string>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Некорректный JSON" }, 400);
  }

  const email = (body.email ?? "").trim();
  const phone = (body.phone ?? "").trim();
  const password = body.password ?? "";
  const fullName = (body.full_name ?? "").trim();
  const language = (body.preferred_language ?? "ru").trim();

  if (!email && !phone) return json({ error: "Укажите email или телефон" }, 400);
  if (password.length < 6) return json({ error: "Пароль не короче 6 символов" }, 400);

  // ── Создание auth-пользователя (service-role) ──────────────────────────────
  const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const payload: Record<string, unknown> = {
    password,
    user_metadata: { full_name: fullName, phone, preferred_language: language },
  };
  if (email) {
    payload.email = email;
    payload.email_confirm = true;
  }
  if (phone) {
    payload.phone = phone;
    payload.phone_confirm = true;
  }

  const { data, error } = await supabaseAdmin.auth.admin.createUser(payload);
  if (error) {
    const dup =
      error.message.toLowerCase().includes("already") ||
      error.message.toLowerCase().includes("duplicate") ||
      (error as unknown as { status?: number }).status === 422;
    return json(
      { error: dup ? "Пользователь с таким email/телефоном уже существует" : error.message },
      400,
    );
  }

  // Триггер создаёт public.users по auth_id. Если задан язык — подтянем его.
  const authUserId = data.user?.id;
  if (authUserId && language && language !== "ru") {
    await supabaseAdmin
      .from("users")
      .update({ preferred_language: language })
      .eq("auth_id", authUserId);
  }

  return json({ success: true, auth_id: authUserId });
});

/**
 * ARS-355: issue a short-lived download URL for a finalized MPK organization
 * document. The browser never receives a durable Storage object key.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};
const BUCKET = "org-documents";
const SIGNED_URL_TTL_SECONDS = 60;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization");
  if (!url || !anonKey || !serviceRoleKey) {
    return json({ error: "Function is not configured" }, 500);
  }
  if (!authorization?.startsWith("Bearer ")) {
    return json({ error: "Authentication required" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const organizationId = body.organization_id;
  const documentId = body.document_id;
  if (!isUuid(organizationId) || !isUuid(documentId)) {
    return json({ error: "organization_id and document_id must be UUIDs" }, 400);
  }

  const caller = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: "Authentication required" }, 401);
  }

  const service = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const { data: storagePath, error: accessError } = await service.rpc(
    "fn_get_org_document_download_path",
    {
      p_actor_auth_id: userData.user.id,
      p_organization_id: organizationId,
      p_document_id: documentId,
    },
  );
  if (accessError || typeof storagePath !== "string") {
    // Do not distinguish a foreign document from a missing/inactive one.
    return json({ error: "Document is unavailable" }, 403);
  }

  const { data: signedUrl, error: signedUrlError } = await service.storage
    .from(BUCKET)
    .createSignedUrl(storagePath, SIGNED_URL_TTL_SECONDS);
  if (signedUrlError || !signedUrl?.signedUrl) {
    return json({ error: "Unable to prepare document download" }, 500);
  }

  return json({
    signed_url: signedUrl.signedUrl,
    expires_in: SIGNED_URL_TTL_SECONDS,
  });
});

function isUuid(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: CORS_HEADERS });
}

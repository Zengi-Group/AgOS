/**
 * ARS-355: remove abandoned private document uploads through the Storage API.
 * Invoke only from a trusted scheduler/worker using the service-role bearer key.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};
const BUCKET = "org-documents";

type CleanupClaim = { document_id: string; storage_path: string };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) return json({ error: "Function is not configured" }, 500);
  if (req.headers.get("Authorization") !== `Bearer ${serviceRoleKey}`) {
    return json({ error: "Unauthorized" }, 401);
  }

  let requestedLimit = 100;
  try {
    const body = await req.json() as { limit?: unknown };
    if (typeof body.limit === "number" && Number.isInteger(body.limit)) {
      requestedLimit = Math.min(Math.max(body.limit, 1), 500);
    }
  } catch {
    // Empty request bodies are valid; the database function supplies the default.
  }

  const service = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const claimToken = crypto.randomUUID();
  const { data: rawClaims, error: claimError } = await service.rpc(
    "fn_claim_org_document_storage_cleanup",
    { p_limit: requestedLimit, p_claim_token: claimToken, p_organization_id: null },
  );
  if (claimError) return json({ error: "Unable to claim document cleanup" }, 500);

  const claims = (rawClaims ?? []).filter(isCleanupClaim);
  if (claims.length === 0) return json({ claimed: 0, cleaned: 0 });

  const { error: removeError } = await service.storage
    .from(BUCKET)
    .remove(claims.map((claim) => claim.storage_path));
  if (removeError) return json({ error: "Unable to remove document objects" }, 500);

  const { data: cleaned, error: markError } = await service.rpc(
    "fn_mark_org_document_storage_cleaned",
    {
      p_document_ids: claims.map((claim) => claim.document_id),
      p_claim_token: claimToken,
    },
  );
  if (markError) return json({ error: "Unable to record document cleanup" }, 500);

  return json({ claimed: claims.length, cleaned: Number(cleaned ?? 0) });
});

function isCleanupClaim(value: unknown): value is CleanupClaim {
  return typeof value === "object"
    && value !== null
    && typeof (value as CleanupClaim).document_id === "string"
    && typeof (value as CleanupClaim).storage_path === "string";
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: CORS_HEADERS });
}

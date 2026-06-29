import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// admin-delete-user — ПОЛНОЕ удаление пользователя: удаляет запись в auth.users,
// что каскадом (public.users.auth_id … on delete cascade) сносит профиль и
// связанные данные. Необратимо. Доступ только админу (JWT → fn_is_admin()).

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

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader) return json({ error: "Не авторизован" }, 401);

  const supabaseAuthed = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: isAdmin, error: adminErr } = await supabaseAuthed.rpc("fn_is_admin");
  if (adminErr) return json({ error: adminErr.message }, 500);
  if (!isAdmin) return json({ error: "Доступ только для администратора" }, 403);

  let body: Record<string, string>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Некорректный JSON" }, 400);
  }

  const userId = (body.user_id ?? "").trim();
  if (!userId) return json({ error: "user_id обязателен" }, 400);

  const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Нужен auth_id для удаления из auth.users
  const { data: profile, error: lookupErr } = await supabaseAdmin
    .from("users")
    .select("auth_id, full_name, email, phone")
    .eq("id", userId)
    .single();
  if (lookupErr || !profile) return json({ error: "Пользователь не найден" }, 404);

  // Аудит ДО удаления (после каскада actor-ссылки на профиль уже не будет)
  await supabaseAdmin.from("platform_events").insert({
    event_type: "identity.user.deleted",
    entity_type: "users",
    entity_id: userId,
    actor_type: "admin",
    payload: {
      deleted: { full_name: profile.full_name, email: profile.email, phone: profile.phone },
    },
    is_audit: true,
  });

  const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(profile.auth_id);
  if (delErr) return json({ error: delErr.message }, 400);

  return json({ success: true });
});

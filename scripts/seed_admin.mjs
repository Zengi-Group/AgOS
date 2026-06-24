// AgOS · Сид админ-аккаунта для входа в админку (/admin/login).
//
// Создаёт (идемпотентно):
//   1) пользователя в auth.users (email+пароль, email уже подтверждён);
//   2) строку public.users (auth_id, email);
//   3) строку public.admin_roles (role='super_admin', is_active=true) →
//      fn_is_admin() начинает возвращать true для этого пользователя.
//
// Запуск:
//   node scripts/seed_admin.mjs
//
// Требуется СЕРВЕРНЫЙ service-role ключ (НЕ VITE_*). Берётся из .env / .env.production
// или из process.env. Значения логина/пароля можно переопределить через окружение:
//   ADMIN_EMAIL=admin@agos.local  ADMIN_PASSWORD=adminagos123
//
// ВАЖНО: пароль НЕ попадает в браузерный бандл. Его вводит человек на форме /admin/login.
// Этот скрипт использует service-role ключ, который живёт только на сервере/локально.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { createClient } from '@supabase/supabase-js'

const __dirname = dirname(fileURLToPath(import.meta.url))

function loadEnv(file) {
  const out = {}
  try {
    for (const raw of readFileSync(resolve(__dirname, '..', file), 'utf8').split('\n')) {
      const line = raw.trim()
      if (!line || line.startsWith('#') || !line.includes('=')) continue
      const i = line.indexOf('=')
      out[line.slice(0, i).trim()] = line.slice(i + 1).trim()
    }
  } catch { /* noop */ }
  return out
}

// .env перекрывает .env.production; process.env перекрывает оба.
const env = { ...loadEnv('.env.production'), ...loadEnv('.env'), ...process.env }

const url = env.SUPABASE_URL || env.VITE_SUPABASE_URL
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY
const adminEmail = (env.ADMIN_EMAIL || 'admin@agos.local').toLowerCase()
const adminPassword = env.ADMIN_PASSWORD || 'adminagos123'

if (!url) {
  console.error('Нет SUPABASE_URL / VITE_SUPABASE_URL в .env')
  process.exit(1)
}
if (!serviceKey) {
  console.error('Нет SUPABASE_SERVICE_ROLE_KEY в .env (серверный ключ, без префикса VITE_).')
  process.exit(1)
}

const supabase = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

// Найти существующего auth-пользователя по email (createUser не возвращает его при дубле).
async function findAuthUserByEmail(email) {
  // listUsers пагинируется; на проде пользователей немного — пройдёмся по страницам.
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 200 })
    if (error) throw new Error('listUsers: ' + error.message)
    const found = (data?.users || []).find((u) => (u.email || '').toLowerCase() === email)
    if (found) return found
    if (!data?.users || data.users.length < 200) break
  }
  return null
}

async function main() {
  console.log('▶ Сид админа:', adminEmail)

  // 1) auth.users — создать или найти существующего.
  let authUser = null
  const created = await supabase.auth.admin.createUser({
    email: adminEmail,
    password: adminPassword,
    email_confirm: true,
    user_metadata: { full_name: 'Администратор AgOS' },
  })
  if (created.error) {
    const msg = created.error.message || ''
    const dup = /already|exist|registered/i.test(msg)
    if (!dup) { console.error('createUser:', msg); process.exit(2) }
    console.log('• auth-пользователь уже есть — обновляю пароль')
    authUser = await findAuthUserByEmail(adminEmail)
    if (!authUser) { console.error('Не нашёл существующего auth-пользователя по email'); process.exit(2) }
    // Гарантируем актуальный пароль и подтверждённый email.
    const upd = await supabase.auth.admin.updateUserById(authUser.id, {
      password: adminPassword, email_confirm: true,
    })
    if (upd.error) { console.error('updateUserById:', upd.error.message); process.exit(2) }
  } else {
    authUser = created.data.user
    console.log('• auth-пользователь создан:', authUser.id)
  }

  // 2) public.users — upsert по auth_id (service-role обходит RLS).
  const upsertUser = await supabase
    .from('users')
    .upsert(
      { auth_id: authUser.id, email: adminEmail, full_name: 'Администратор AgOS', is_active: true },
      { onConflict: 'auth_id' },
    )
    .select('id')
    .single()
  if (upsertUser.error) { console.error('users upsert:', upsertUser.error.message); process.exit(3) }
  const publicUserId = upsertUser.data.id
  console.log('• public.users.id:', publicUserId)

  // 3) admin_roles — upsert по user_id (уникальный), role=super_admin, активна.
  const upsertRole = await supabase
    .from('admin_roles')
    .upsert(
      { user_id: publicUserId, role: 'super_admin', is_active: true },
      { onConflict: 'user_id' },
    )
    .select('id')
    .single()
  if (upsertRole.error) { console.error('admin_roles upsert:', upsertRole.error.message); process.exit(4) }
  console.log('• admin_roles.id:', upsertRole.data.id, '(super_admin, active)')

  console.log('\n✅ Готово. Вход в админку:')
  console.log('   URL:    /admin/login')
  console.log('   Логин:  ' + adminEmail.split('@')[0])
  console.log('   Пароль: (тот, что в ADMIN_PASSWORD)')
}

main().catch((e) => { console.error(e); process.exit(9) })

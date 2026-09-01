// AgOS · Сид QA-тестового МПК для превью /mpk без ручного прохождения визарда
// (регистрация на реальных номерах сейчас недоступна — оператор Beeline блокируется
// на стороне Mobizon, см. диагностику 2026-08-27).
//
// Создаёт (идемпотентно), используя ТЕ ЖЕ RPC, что и настоящий МПК (zero duplication, P-AI-1):
//   1) auth.users (phone+PIN как password, phone уже подтверждён) — через Admin API;
//   2) сессию под этим пользователем (signInWithPassword) → rpc_register_organization (mpk).
//
// БИН намеренно null (как и в seed_farmer.mjs) — фиктивный БИН рискует случайно
// совпасть с реальным мясокомбинатом; rpc_register_organization проверяет уникальность
// БИН только если он передан (d01_kernel.sql:3933).
//
// Запуск:
//   node scripts/seed_mpk.mjs
//
// Требуется SUPABASE_SERVICE_ROLE_KEY в .env (серверный, НЕ VITE_*) — как в seed_farmer.mjs.

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

const env = { ...loadEnv('.env.production'), ...loadEnv('.env'), ...process.env }

const url = env.SUPABASE_URL || env.VITE_SUPABASE_URL
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY
const anonKey = env.VITE_SUPABASE_ANON_KEY || env.SUPABASE_ANON_KEY

if (!url) { console.error('Нет SUPABASE_URL / VITE_SUPABASE_URL в .env'); process.exit(1) }
if (!serviceKey) { console.error('Нет SUPABASE_SERVICE_ROLE_KEY в .env'); process.exit(1) }
if (!anonKey) { console.error('Нет VITE_SUPABASE_ANON_KEY / SUPABASE_ANON_KEY в .env'); process.exit(1) }

// Постоянный QA-фикстур (переиспользуемый, аналог seed_farmer.mjs). Явно тестовый
// номер (KZ-формат, не пересекается с реальными фермерами/МПК — другой хвост, чем у
// seed_farmer.mjs), 6-значный PIN как того требует src/pages/auth/Login.tsx.
const PHONE = '+77010000002'
const PIN = '123456'
const COMPANY_NAME = 'ТОО QA-Тест МПК'
const REGION_CODE = 'KZ-AKM' // Акмолинская — тот же выбор, что и в seed_farmer.mjs

// Значения — из списков COMPANY_TYPES / MONTHLY_VOLUMES в src/pages/registration/constants.ts.
const COMPANY_TYPE = 'meatpacking'
const MONTHLY_VOLUME = '100_500'

const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } })
const anon = createClient(url, anonKey, { auth: { autoRefreshToken: false, persistSession: false } })

async function findAuthUserByPhone(phone) {
  const digits = phone.replace(/^\+/, '')
  // Быстрый путь: public.users.phone — точечный запрос по одной строке, не зависит от
  // admin.auth.admin.listUsers() (см. фолбэк ниже). При повторных запусках МПК уже
  // существует — это основной путь, listUsers вообще не вызывается.
  const { data: pubUser } = await admin.from('users').select('auth_id').eq('phone', digits).maybeSingle()
  if (pubUser?.auth_id) {
    const { data, error } = await admin.auth.admin.getUserById(pubUser.auth_id)
    if (!error && data?.user) return data.user
  }
  // Фолбэк: пагинированный listUsers сканирует ВСЕ строки auth.users и падает целиком,
  // если хотя бы одна строка в таблице битая (NULL в confirmation_token и т.п. — баг GoTrue
  // admin API на строках, вставленных мимо обычного signup; 2026-07-21, ARS-280 QA). Не валим
  // весь сид — предупреждаем и продолжаем без найденного пользователя.
  try {
    for (let page = 1; page <= 50; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 })
      if (error) throw new Error('listUsers: ' + error.message)
      const found = (data?.users || []).find((u) => u.phone === digits)
      if (found) return found
      if (!data?.users || data.users.length < 200) break
    }
  } catch (e) {
    console.warn('• findAuthUserByPhone: listUsers-фолбэк упал (битые строки в auth.users), продолжаю без него:', e.message)
  }
  return null
}

async function main() {
  console.log('▶ Сид QA-МПК:', PHONE)

  // 1) auth.users — создать или найти существующего (Admin API хранит phone без «+»).
  let authUser = null
  const created = await admin.auth.admin.createUser({
    phone: PHONE,
    password: PIN,
    phone_confirm: true,
    user_metadata: { full_name: 'Тестовый МПК QA' },
  })
  if (created.error) {
    const msg = created.error.message || ''
    if (!/already|exist|registered/i.test(msg)) { console.error('createUser:', msg); process.exit(2) }
    console.log('• auth-пользователь уже есть — обновляю PIN')
    authUser = await findAuthUserByPhone(PHONE)
    if (!authUser) { console.error('Не нашёл существующего auth-пользователя по телефону'); process.exit(2) }
    const upd = await admin.auth.admin.updateUserById(authUser.id, { password: PIN, phone_confirm: true })
    if (upd.error) { console.error('updateUserById:', upd.error.message); process.exit(2) }
  } else {
    authUser = created.data.user
    console.log('• auth-пользователь создан:', authUser.id)
  }

  // 2) Сессия под МПК (тот же путь, что и Login.tsx) — дальше только штатные RPC.
  const signIn = await anon.auth.signInWithPassword({ phone: PHONE, password: PIN })
  if (signIn.error) { console.error('signInWithPassword:', signIn.error.message); process.exit(3) }
  const session = signIn.data.session
  const mpk = createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${session.access_token}` } },
  })

  // 3) Организация — идемпотентно: если уже зарегистрирована, переиспользуем.
  //    org_type='mpk' не создаёт запись в farms (d01_kernel.sql:3991 — только для 'farmer').
  const { data: pubUser } = await admin.from('users').select('id').eq('auth_id', authUser.id).single()
  const { data: existingRole } = await admin
    .from('user_organization_roles')
    .select('organization_id')
    .eq('user_id', pubUser.id)
    .limit(1)
    .maybeSingle()

  let orgId
  if (existingRole) {
    orgId = existingRole.organization_id
    console.log('• организация уже существует — переиспользую:', orgId)
  } else {
    const { data: region } = await admin.from('regions').select('id').eq('code', REGION_CODE).single()
    const reg = await mpk.rpc('rpc_register_organization', {
      p_organization_id: null,
      p_org_type: 'mpk',
      p_name: COMPANY_NAME,
      p_bin: null,
      p_region_id: region.id,
      p_phone: PHONE,
      p_invited_by: null,
      p_role_data: {
        company_type: COMPANY_TYPE,
        monthly_volume: MONTHLY_VOLUME,
        target_breeds: null,
        target_weight: null,
        procurement_frequency: null,
        full_name: 'Тестовый МПК QA',
      },
    })
    if (reg.error) { console.error('rpc_register_organization:', reg.error.message); process.exit(4) }
    orgId = reg.data.org_id
    console.log('• организация создана:', orgId)
  }

  console.log('\n✅ Готово. Вход в кабинет (/mpk, роут /login):')
  console.log('   Телефон: ' + PHONE)
  console.log('   PIN:     ' + PIN)
}

main().catch((e) => { console.error(e); process.exit(9) })

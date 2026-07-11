// AgOS · Сид QA-тестового фермера для превью /cabinet (state C и т.п.) без ручного прохождения
// визарда. Постоянный фикстур-аккаунт — телефон+PIN ниже намеренно захардкожены (это синтетический
// тестовый фермер без реальных ПДн, создаётся для внутреннего QA/превью; см. qa/README.md §4a
// «seed-аккаунты» — это они).
//
// Создаёт (идемпотентно), используя ТЕ ЖЕ RPC, что и настоящий фермер (zero duplication, P-AI-1):
//   1) auth.users (phone+PIN как password, phone уже подтверждён) — через Admin API;
//   2) сессию под этим пользователем (signInWithPassword) → rpc_register_organization (farmer);
//   3) стадо (COW=25, rpc_upsert_herd_group) + сезонный отёл (rpc_upsert_farm calving_system='spring');
//   4) draft-ЦТК (rpc_generate_plan_from_profile) — чтобы таб «Ферма» сразу открывался в state C.
//
// Запуск:
//   node scripts/seed_farmer.mjs
//
// Требуется SUPABASE_SERVICE_ROLE_KEY в .env (серверный, НЕ VITE_*) — как в seed_admin.mjs.

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

// Постоянный QA-фикстур (переиспользуемый — см. память «agos-qa-seed-farmer»). Явно тестовый
// номер (KZ-формат, не пересекается с реальными фермерами), 6-значный PIN как того требует
// src/pages/auth/Login.tsx.
const PHONE = '+77010000001'
const PIN = '123456'
const FARM_NAME = 'КХ QA-Тест'
const REGION_CODE = 'KZ-AKM' // Акмолинская — первая по sort_order, произвольный выбор

const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } })
const anon = createClient(url, anonKey, { auth: { autoRefreshToken: false, persistSession: false } })

async function findAuthUserByPhone(phone) {
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 })
    if (error) throw new Error('listUsers: ' + error.message)
    const found = (data?.users || []).find((u) => u.phone === phone.replace(/^\+/, ''))
    if (found) return found
    if (!data?.users || data.users.length < 200) break
  }
  return null
}

async function main() {
  console.log('▶ Сид QA-фермера:', PHONE)

  // 1) auth.users — создать или найти существующего (Admin API хранит phone без «+»).
  let authUser = null
  const created = await admin.auth.admin.createUser({
    phone: PHONE,
    password: PIN,
    phone_confirm: true,
    user_metadata: { full_name: 'Тестовый Фермер QA' },
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

  // 2) Сессия под фермером (тот же путь, что и Login.tsx) — дальше только штатные RPC.
  const signIn = await anon.auth.signInWithPassword({ phone: PHONE, password: PIN })
  if (signIn.error) { console.error('signInWithPassword:', signIn.error.message); process.exit(3) }
  const session = signIn.data.session
  const farmer = createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${session.access_token}` } },
  })

  // 3) Организация+ферма — идемпотентно: если уже зарегистрирован, переиспользуем.
  const { data: pubUser } = await admin.from('users').select('id').eq('auth_id', authUser.id).single()
  const { data: existingRole } = await admin
    .from('user_organization_roles')
    .select('organization_id')
    .eq('user_id', pubUser.id)
    .limit(1)
    .maybeSingle()

  let orgId, farmId
  if (existingRole) {
    orgId = existingRole.organization_id
    const { data: farm } = await admin.from('farms').select('id').eq('organization_id', orgId).eq('is_primary', true).single()
    farmId = farm.id
    console.log('• организация/ферма уже существуют — переиспользую:', orgId, farmId)
  } else {
    const { data: region } = await admin.from('regions').select('id').eq('code', REGION_CODE).single()
    const reg = await farmer.rpc('rpc_register_organization', {
      p_organization_id: null,
      p_org_type: 'farmer',
      p_name: FARM_NAME,
      p_bin: null,
      p_region_id: region.id,
      p_phone: PHONE,
      p_invited_by: null,
      p_role_data: { farm_name: FARM_NAME },
    })
    if (reg.error) { console.error('rpc_register_organization:', reg.error.message); process.exit(4) }
    orgId = reg.data.org_id
    farmId = reg.data.farm_id
    console.log('• организация/ферма созданы:', orgId, farmId)
  }

  // 4) Стадо (COW=25) + сезонный отёл — те же RPC, что и мастер (farm-profile.ts).
  const cow = await admin.rpc('rpc_upsert_herd_group', {
    p_organization_id: orgId, p_farm_id: farmId,
    p_animal_category_code: 'COW', p_head_count: 25, p_data_source: 'platform',
  })
  if (cow.error) console.warn('rpc_upsert_herd_group:', cow.error.message)

  const upsertFarm = await admin.rpc('rpc_upsert_farm', {
    p_organization_id: orgId, p_farm_id: farmId, p_name: null, p_region_id: null,
    p_shelter_type: null, p_calving_system: 'spring',
  })
  if (upsertFarm.error) console.warn('rpc_upsert_farm:', upsertFarm.error.message)

  // 5) Draft-ЦТК (ARS-213 → ARS-215 state C) — порог достигнут (COW>0 + calving_system).
  const gen = await admin.rpc('rpc_generate_plan_from_profile', {
    p_organization_id: orgId, p_farm_id: farmId, p_first_calving_month: 3, p_actor_id: pubUser.id,
  })
  if (gen.error) console.warn('rpc_generate_plan_from_profile:', gen.error.message)
  else console.log('• план:', gen.data)

  console.log('\n✅ Готово. Вход в кабинет (/cabinet, роут /login):')
  console.log('   Телефон: ' + PHONE)
  console.log('   PIN:     ' + PIN)
}

main().catch((e) => { console.error(e); process.exit(9) })

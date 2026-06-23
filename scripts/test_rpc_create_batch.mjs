// AgOS · TSP-1 · Тест rpc_create_batch через supabase.rpc() (ТЗ часть 13, задачи 3–4).
//
// Запуск:
//   node scripts/test_rpc_create_batch.mjs
//
// Требуется аутентифицированный фермер (RPC читает auth.uid()). Передайте сессию
// тестового пользователя через переменные окружения:
//   TEST_EMAIL=farmer@example.com TEST_PASSWORD=*** node scripts/test_rpc_create_batch.mjs
// Без них вызов вернётся с ORG_NOT_FOUND / RLS-ошибкой (auth.uid() = null).
//
// URL и anon-ключ берутся из .env.production (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY).

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

const env = { ...loadEnv('.env.production'), ...process.env }
const url = env.VITE_SUPABASE_URL
const anon = env.VITE_SUPABASE_ANON_KEY
if (!url || !anon) {
  console.error('Нет VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY')
  process.exit(1)
}

const supabase = createClient(url, anon)

// Требуемые ключи типа Batch в возвращаемом JSONB (ТЗ часть 13, задача 4).
const REQUIRED = [
  'id', 'cat', 'heads', 'avgWeight', 'age', 'breed', 'fatness', 'district',
  'price', 'dealPrice', 'state', 'windowLabel', 'publishAtLabel', 'deadlineLabel', 'history',
]

const payload = {
  p_cat: 'bychki',
  p_breed: 'Ангус',
  p_heads: 10,
  p_avg_weight: 450,
  p_age: 24,
  p_fatness: 'Хорошая',
  p_district: 'Сайрамский район',
  p_price: 1550,
  p_window_from: '2026-07-01',
  p_window_to: '2026-07-15',
  p_scheduled: false,
}

async function main() {
  if (env.TEST_EMAIL && env.TEST_PASSWORD) {
    const { error } = await supabase.auth.signInWithPassword({
      email: env.TEST_EMAIL, password: env.TEST_PASSWORD,
    })
    if (error) { console.error('Auth error:', error.message); process.exit(2) }
    console.log('Авторизован как', env.TEST_EMAIL)
  } else {
    console.warn('⚠  TEST_EMAIL/TEST_PASSWORD не заданы — вызов пойдёт без сессии (ожидается ошибка ORG_NOT_FOUND).')
  }

  const { data, error } = await supabase.rpc('rpc_create_batch', payload)
  if (error) {
    console.error('RPC error:', JSON.stringify(error, null, 2))
    process.exit(3)
  }

  console.log('\nВозвращённый JSONB:')
  console.log(JSON.stringify(data, null, 2))

  const missing = REQUIRED.filter((k) => !(data && Object.prototype.hasOwnProperty.call(data, k)))
  if (missing.length) {
    console.error('\n❌ Отсутствуют ключи Batch:', missing.join(', '))
    process.exit(4)
  }
  console.log('\n✅ Все требуемые ключи типа Batch присутствуют. state =', data.state)
}

main().catch((e) => { console.error(e); process.exit(9) })

// AgOS · Slice10 · MP-3.7 (ARS-628) — модель вкладки «Обзор» и ЕДИНЫЙ словарь вердикта
// допуска.
//
// ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ (§3.0 «Дом вердикта допуска — БАЗА», решение владельца
// 2026-09-09). Вердикт «можем ли мы закупать прямо сейчас» считает база
// (`admission.status` агрегата), а формулировку берут ОБА места, где он показан: бейдж
// шапки консоли и заголовок «Обзора». Словарь лежит здесь именно поэтому — чтобы его
// нельзя было переиспользовать наполовину.
//
// Первый заход MP-3.7 переиспользовал словарь бейджа MP-3.1 и НЕ переиспользовал его
// вывод: получилось два независимых вычисления одного факта на одном экране, дословно
// расходящихся при `verification = conditional` («Допуск не подтверждён» рядом с «Допущен
// с условиями»). На тогдашних прод-данных расхождение было недостижимо ПО ДАННЫМ, а не по
// коду, — то есть уехало бы в прод зелёным. Маршрут `bad_spec`, откат, §3.0 (`KEEP-7`).
//
// Форма ответа выверена по SQL (`d01_kernel.sql`, блок `ARS-646 / MP-2.2`, `jsonb_build_object`
// в конце функции), а не по доку — `L-6`. Гейт `documents` НЕ несёт `tone` (`KEEP-1`).

import { supabase } from '@/lib/supabase'
import type { MpkProfileTab } from '../types'
import { parseRpcCode, type CriticalFieldName, type LoadFailure } from './OrgSection'

// HS-4: наружу выходит только то, что читают потребители (`OverviewSection` и оболочка).
const OVERVIEW_CONTRACT_VERSION = 1

export type Tone = 'ok' | 'warning' | 'info' | 'unknown'

const ADMISSION_STATUSES = ['allowed', 'allowed_conditional', 'restricted', 'pending', 'unknown'] as const
export type AdmissionStatus = (typeof ADMISSION_STATUSES)[number]

interface Unavailable { available: false; blocked_by: string }
export type FactValue = number | Unavailable

export interface VerificationGate {
  kind: 'verification'
  tone: Tone
  available: true
  status: string | null
  approved_at: string | null
  pending_field_count: number
}

export interface MembershipGate {
  kind: 'membership'
  tone: Tone
  available: true
  is_active: boolean
  source: string | null
  days_left: number | null
  current_period_end: string | null
  plan_title: string | null
  cta: string | null
}

export interface DocumentsGate { kind: 'documents'; available: false; blocked_by: string }

export type OverviewGate = VerificationGate | MembershipGate | DocumentsGate

export type AttentionActionType = 'open_admission' | 'open_org' | 'open_reputation'

interface AttentionBase { priority: number; tone: Tone; action: { type: AttentionActionType } }

export type AttentionItem =
  | (AttentionBase & { kind: 'membership_expiring'; days_left: number; current_period_end: string | null })
  | (AttentionBase & { kind: 'pending_field_review'; field_count: number; fields: CriticalFieldName[] })
  | (AttentionBase & { kind: 'hidden_review'; count: number; counterparty_name: string | null })

export interface OverviewReputation {
  review_count: number
  average_score: number | null
  weight_accuracy_average: number | null
}

export interface OverviewPayload {
  contract_version: number
  organization_id: string
  admission: { status: AdmissionStatus; checked_at: string | null; has_pending_reviews: boolean }
  gates: OverviewGate[]
  attention: AttentionItem[]
  reputation: OverviewReputation | null
  facts: { staff_active: FactValue; deals_closed: FactValue; heads_accepted: FactValue; supplier_orgs: FactValue }
  permissions: Record<string, boolean>
}

export const OVERVIEW_READ_FALLBACK =
  'Не удалось загрузить сводку по предприятию. Проверьте соединение и повторите.'

// ── Единый словарь вердикта (§3.2, черновик сборки — правит владелец).
// Значение вне перечня рисуется как `unknown`, а не пустой строкой (`KEEP-14`): перечень
// закрыт в контракте, но закрытость контракта — не то же, что проверка на входе.

const ADMISSION_TITLE: Record<AdmissionStatus, string> = {
  allowed: 'Допущен к закупкам',                    // прототип L2207
  allowed_conditional: 'Допущен с условиями',
  restricted: 'Закупки закрыты',
  pending: 'Проверка идёт',
  unknown: 'Статус уточняется',
}

const ADMISSION_TONE: Record<AdmissionStatus, Tone> = {
  allowed: 'ok',
  allowed_conditional: 'info',
  restricted: 'warning',
  pending: 'info',
  unknown: 'unknown',
}

// Бейджу шапки нужен свой набор классов тона — он существует с MP-3.1 и его CSS не
// переписывается (`P7`). Соответствие тон → класс бейджа, а не второй словарь статусов.
// Класса `red` в этом наборе НЕТ: его единственным источником был `verification.status =
// 'rejected'` в удалённом клиентском выводе, а перечень базы схлопывает `rejected` в
// `restricted` (тон `warning`). Правило `.mpkc-badge.red` в CSS осталось от MP-3.1 и
// сейчас недостижимо — помечено там же; не вписываем недостижимый вариант ещё и в тип (`HS-4`).
const BADGE_TONE: Record<Tone, 'green' | 'amber' | 'neutral'> = {
  ok: 'green',
  warning: 'amber',
  info: 'amber',
  unknown: 'neutral',
}

function normalizeAdmissionStatus(value: unknown): AdmissionStatus {
  return (ADMISSION_STATUSES as readonly string[]).includes(value as string)
    ? (value as AdmissionStatus)
    : 'unknown'
}

export function admissionTitle(status: AdmissionStatus): string {
  return ADMISSION_TITLE[normalizeAdmissionStatus(status)]
}

export function admissionTone(status: AdmissionStatus): Tone {
  return ADMISSION_TONE[normalizeAdmissionStatus(status)]
}

// Бейдж шапки и заголовок «Обзора» — одна строка из одного словаря (§3.0 п.2/п.3).
export function admissionBadgeFromVerdict(status: AdmissionStatus): {
  tone: 'green' | 'amber' | 'neutral'
  label: string
} {
  const st = normalizeAdmissionStatus(status)
  return { tone: BADGE_TONE[ADMISSION_TONE[st]], label: ADMISSION_TITLE[st] }
}

export function admissionSub(status: AdmissionStatus, hasPendingReviews: boolean): string {
  switch (normalizeAdmissionStatus(status)) {
    case 'allowed':
      // Оба варианта — прототип L2209/L2210. Они утверждают «Верификация, членство и
      // документы в порядке», что правда ТОЛЬКО при `allowed`; переносить их на другие
      // статусы значило бы утверждать неправду.
      return hasPendingReviews
        ? 'Верификация, членство и документы в порядке. Изменения реквизитов проверяются — на закупки это не влияет.'
        : 'Верификация, членство и документы в порядке. Ограничений на заявки и приёмку нет.'
    case 'allowed_conditional':
      return 'Закупки открыты с условиями — что именно требуется, показано в гейтах ниже.'
    case 'restricted':
      return 'Заявки и приёмка сейчас закрыты. Что именно закрывает закупки — в гейтах ниже.'
    case 'pending':
      return 'TURAN проверяет предприятие. До решения закупки не открыты.'
    default:
      return 'Данных верификации пока нет — это не отказ. Статус появится, когда TURAN проверит предприятие.'
  }
}

// ── Формат

function stripYearSuffix(s: string): string {
  return s.replace(/ г\.$/, '')
}

export function formatDay(iso: string | null): string | null {
  if (!iso) return null
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return null
    return stripYearSuffix(d.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' }))
  } catch { return null }
}

// `ov_checked` прототипа — «обновлено сегодня, 09:14». Слово «сегодня» здесь не догадка:
// `admission.checked_at` в SQL = `now()`, то есть момент чтения (Dok3 RPC-64). Ветки «другой
// день» НЕТ намеренно — она недостижима по контракту, а код под недостижимое состояние
// запрещён (`HS-4`, `KEEP-20`; ветка была в первом заходе и снята как `unrequested`).
// ЕСЛИ дом значения когда-нибудь сменится с «время чтения» на «время последней проверки» —
// эта строка обязана поменяться вместе с ним.
export function formatChecked(iso: string | null): string | null {
  if (!iso) return null
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return null
    return `обновлено сегодня, ${d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}`
  } catch { return null }
}

export function formatNumber(n: number): string {
  return n.toLocaleString('ru-RU')
}

export function formatScore(n: number): string {
  return n.toLocaleString('ru-RU', { minimumFractionDigits: 1, maximumFractionDigits: 1 })
}

export function plural(n: number, one: string, few: string, many: string): string {
  const mod100 = n % 100
  if (mod100 >= 11 && mod100 <= 14) return many
  const mod10 = n % 10
  if (mod10 === 1) return one
  if (mod10 >= 2 && mod10 <= 4) return few
  return many
}

export const ACTION_TAB: Record<AttentionActionType, MpkProfileTab> = {
  open_admission: 'adm',
  open_org: 'org',
  open_reputation: 'rep',
}

// ── Загрузка. Тот же приём, что у читателя раздела «Предприятие» (`loadOrgProfile`):
// сбой промиса — НЕ код RPC, через `parseRpcCode` не пропускается (`KEEP-6`).

export async function loadOverview(
  organizationId: string,
): Promise<{ payload: OverviewPayload } | { failure: LoadFailure }> {
  let data: unknown
  let error: { message?: string } | null
  try {
    const res = await supabase.rpc('rpc_get_mpk_profile_overview', { p_organization_id: organizationId })
    data = res.data
    error = res.error
  } catch (e) {
    console.error('OverviewSection: rpc_get_mpk_profile_overview threw:', e)
    return { failure: { kind: 'local', message: OVERVIEW_READ_FALLBACK } }
  }
  if (error) {
    console.error('OverviewSection: rpc_get_mpk_profile_overview error:', error)
    return { failure: { kind: 'rpc', code: parseRpcCode(error.message) } }
  }
  const payload = data as OverviewPayload | null
  // `KEEP-3`: проверяем ВСЕ ветки, которые читает экран, а не только версию — урок B.5
  // круга ARS-624 (`version = 1` формы не гарантирует).
  //
  // Круг правок итерации 2: первая редакция проверяла из `reputation` один подключ из трёх,
  // а `facts` — только на существование объекта. Оба пробела вели в одно и то же:
  // `undefined` проходит сравнение `!== null`, а `isUnavailable(undefined)` даёт `false`,
  // после чего `formatNumber(undefined)` роняет `toLocaleString` и консоль уходит в белый
  // экран. Проверяем каждое поле, которое реально читается ниже.
  if (
    !payload
    || payload.contract_version !== OVERVIEW_CONTRACT_VERSION
    || !payload.admission
    || !Array.isArray(payload.gates)
    || !Array.isArray(payload.attention)
    || !payload.facts
    || !FACT_KEYS.every((k) => isFactValue(payload.facts?.[k]))
    || !payload.permissions
    || !isReputation(payload.reputation)
  ) {
    console.error('OverviewSection: unexpected rpc_get_mpk_profile_overview payload shape', payload)
    return { failure: { kind: 'local', message: 'Контракт ответа не распознан. Обновите страницу.' } }
  }
  return { payload }
}

const FACT_KEYS = ['staff_active', 'deals_closed', 'heads_accepted', 'supplier_orgs'] as const

function isFactValue(v: unknown): boolean {
  if (typeof v === 'number') return true
  return typeof v === 'object' && v !== null && (v as Unavailable).available === false
}

// `reputation` разрешено быть `null` — так объявлено в SQL (сквозной проброс ответа
// ARS-360, который у организации без отзывов может не собраться). Но если объект есть,
// каждое читаемое поле обязано быть числом либо `null`: строка вместо числа прошла бы
// `!== null` и молча нарисовала «оценок пока нет» при существующих отзывах.
function isReputation(v: unknown): boolean {
  if (v == null) return true
  if (typeof v !== 'object') return false
  const r = v as Record<string, unknown>
  return typeof r.review_count === 'number'
    && isScoreOrNull(r.average_score)
    && isScoreOrNull(r.weight_accuracy_average)
}

function isScoreOrNull(v: unknown): boolean {
  return v === null || typeof v === 'number'
}

export function hasScore(value: number | null | undefined): value is number {
  return typeof value === 'number'
}

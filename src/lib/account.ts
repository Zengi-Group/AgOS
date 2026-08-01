// Аккаунт-контекст: единый источник «кто я + какие организации» для роутинга и профиля.
// Источник истины — rpc_get_my_context (RPC-04). Поддерживает несколько организаций
// на одном пользователе (фермер + МПК) без конфликтов.

import { supabase } from '@/lib/supabase'

export interface MyOrg {
  id: string
  legal_name: string | null
  bin_iin: string | null
  region_id: string | null
  phone: string | null
  role: string | null
  is_primary: boolean | null
  org_types: string[]
}

export interface MyFarm {
  id: string
  organization_id: string
  name: string | null
  region_id: string | null
  is_primary: boolean | null
}

export interface MyMembership {
  id: string
  organization_id: string
  org_type: string | null
  level: string | null
}

export interface MyContext {
  user_id: string
  organizations: MyOrg[]
  farms: MyFarm[]
  memberships: MyMembership[]
}

// ARS-361: клиентский read-model канонического членства и верификации. Это именно
// нормализованный ответ защищённого RPC, а не разрешение на действие: все write/gate
// проверки по-прежнему выполняет сервер.
export type CanonicalMembershipState =
  | 'trialing'
  | 'active'
  | 'grace'
  | 'past_due'
  | 'expired'
  | 'canceled'
  | 'revoked'

export type CanonicalMembershipSource = 'subscription' | 'legacy_membership' | 'none'

export type CanonicalVerificationStatus =
  | 'not_mpk'
  | 'incomplete'
  | 'approved'
  | 'rejected'
  | 'conditional'
  | 'expired'

export interface CanonicalMembershipPlan {
  code: string | null
  title: string | null
}

export interface CanonicalMembershipReadModel {
  isActive: boolean
  source: CanonicalMembershipSource
  state: CanonicalMembershipState | null
  trialEnd: string | null
  currentPeriodStart: string | null
  currentPeriodEnd: string | null
  nextBillingAt: string | null
  cancelAtPeriodEnd: boolean | null
  subscriptionId: string | null
  plan: CanonicalMembershipPlan | null
  renewalMode: string | null
  cta: string | null
}

export interface CanonicalTypeAssignmentReadModel {
  assignedAt: string | null
  assignedByUserId: string | null
  isSelfAssigned: boolean | null
}

export interface CanonicalVerificationTimelineEntry {
  id: string | null
  verificationType: string | null
  result: string | null
  verifiedAt: string | null
  expiresAt: string | null
  createdAt: string | null
  effectiveStatus: CanonicalVerificationStatus | null
}

export interface CanonicalVerificationReadModel {
  membershipId: string | null
  status: CanonicalVerificationStatus | null
  typeAssignment: CanonicalTypeAssignmentReadModel | null
  timeline: CanonicalVerificationTimelineEntry[]
  latestByType: CanonicalVerificationTimelineEntry[]
}

export interface OrgMembershipVerificationReadModel {
  version: number | null
  organizationId: string | null
  associationNumber: string | null
  membership: CanonicalMembershipReadModel
  verification: CanonicalVerificationReadModel | null
}

type UnknownRecord = Record<string, unknown>

const MEMBERSHIP_STATES = ['trialing', 'active', 'grace', 'past_due', 'expired', 'canceled', 'revoked'] as const
const MEMBERSHIP_SOURCES = ['subscription', 'legacy_membership', 'none'] as const
const VERIFICATION_STATUSES = ['not_mpk', 'incomplete', 'approved', 'rejected', 'conditional', 'expired'] as const

function asRecord(value: unknown): UnknownRecord | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as UnknownRecord
    : null
}

function asNullableString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function asNullableBoolean(value: unknown): boolean | null {
  return typeof value === 'boolean' ? value : null
}

function asKnownValue<T extends string>(value: unknown, allowed: readonly T[]): T | null {
  return typeof value === 'string' && (allowed as readonly string[]).includes(value) ? value as T : null
}

function parseVerificationEntry(value: unknown): CanonicalVerificationTimelineEntry | null {
  const row = asRecord(value)
  if (!row) return null
  return {
    id: asNullableString(row.id),
    verificationType: asNullableString(row.verification_type),
    result: asNullableString(row.result),
    verifiedAt: asNullableString(row.verified_at),
    expiresAt: asNullableString(row.expires_at),
    createdAt: asNullableString(row.created_at),
    effectiveStatus: asKnownValue(row.effective_status, VERIFICATION_STATUSES),
  }
}

function parseVerificationEntries(value: unknown): CanonicalVerificationTimelineEntry[] {
  if (!Array.isArray(value)) return []
  return value.map(parseVerificationEntry).filter((entry): entry is CanonicalVerificationTimelineEntry => entry !== null)
}

// Не доверяем JSON из RPC на уровне UI: при частичном/старом деплое просто вернёмся к
// прежнему rpc_get_org_subscription и legacy membership вместо ложного «approved».
export function parseOrgMembershipVerificationReadModel(value: unknown): OrgMembershipVerificationReadModel | null {
  const root = asRecord(value)
  const membership = asRecord(root?.membership)
  if (!root || !membership || typeof membership.is_active !== 'boolean') return null

  const verification = asRecord(root.verification)
  const typeAssignment = asRecord(verification?.type_assignment)

  return {
    version: typeof root.version === 'number' ? root.version : null,
    organizationId: asNullableString(root.organization_id),
    associationNumber: asNullableString(root.association_number),
    membership: {
      isActive: membership.is_active,
      source: asKnownValue(membership.source, MEMBERSHIP_SOURCES) ?? 'none',
      state: asKnownValue(membership.state, MEMBERSHIP_STATES),
      trialEnd: asNullableString(membership.trial_end),
      currentPeriodStart: asNullableString(membership.current_period_start),
      currentPeriodEnd: asNullableString(membership.current_period_end),
      nextBillingAt: asNullableString(membership.next_billing_at),
      cancelAtPeriodEnd: asNullableBoolean(membership.cancel_at_period_end),
      subscriptionId: asNullableString(membership.subscription_id),
      plan: membership.plan_code !== undefined || membership.plan_title !== undefined ? {
        code: asNullableString(membership.plan_code),
        title: asNullableString(membership.plan_title),
      } : null,
      renewalMode: asNullableString(membership.renewal_mode),
      cta: asNullableString(membership.cta),
    },
    verification: verification ? {
      membershipId: asNullableString(verification.membership_id),
      status: asKnownValue(verification.status, VERIFICATION_STATUSES),
      typeAssignment: typeAssignment ? {
        assignedAt: asNullableString(typeAssignment.assigned_at),
        assignedByUserId: asNullableString(typeAssignment.assigned_by_user_id),
        isSelfAssigned: asNullableBoolean(typeAssignment.is_self_assigned),
      } : null,
      timeline: parseVerificationEntries(verification.timeline),
      latestByType: parseVerificationEntries(verification.latest_by_type),
    } : null,
  }
}

// Читает контекст текущего пользователя. null = не авторизован / нет данных / бэкенд недоступен.
export async function loadMyContext(): Promise<MyContext | null> {
  const { data, error } = await supabase.rpc('rpc_get_my_context')
  if (error) {
    // 2026-07-21 (ARS-280 QA, «Failed to load user context»): раньше ошибка глоталась в null
    // без следа — сбой RPC был неотличим в логах от «не авторизован». Логируем, поведение
    // (null при ошибке) не меняем.
    console.error('loadMyContext: rpc_get_my_context error:', error)
    return null
  }
  if (!data) return null
  const ctx = data as Partial<MyContext>
  if (!ctx.user_id) return null
  return {
    user_id: ctx.user_id,
    // Нормализация org_types оставлена как защитный слой на случай будущего разъезда
    // SQL≠деплой (проверено 2026-07-21: задеплоенный rpc_get_my_context уже возвращает
    // org_types массивом, как в d01_kernel.sql — прежний ДЕФЕКТ здесь устарел/почищен).
    organizations: (ctx.organizations ?? []).map((o) => {
      const raw = o as MyOrg & { org_type?: string | null }
      const types = Array.isArray(raw.org_types)
        ? raw.org_types
        : (raw.org_type ? [raw.org_type] : [])
      return { ...raw, org_types: types }
    }),
    farms: ctx.farms ?? [],
    memberships: ctx.memberships ?? [],
  }
}

// Выбор шелла по типам организаций. МПК → /mpk, иначе фермерский кабинет.
export function pickShellPath(ctx: MyContext | null): string {
  const types = ctx?.organizations.flatMap((o) => o.org_types) ?? []
  if (types.includes('farmer')) return '/cabinet'
  if (types.includes('mpk')) return '/mpk'
  return '/cabinet'
}

// Профиль для шапки кабинета/МПК. null = демо-режим (аноним / бэкенд недоступен).
export interface AccountProfile {
  userId: string
  orgId: string | null         // organizations.id выбранной организации
  name: string | null          // org legal_name
  bin: string | null
  district: string | null      // regions.name_ru по region_id
  ownerName: string | null     // auth user_metadata.full_name
  legalForm: string | null     // auth user_metadata.legal_form (kh/ip/too/individual) из деталей фермера
  phone: string | null
  orgTypes: string[]           // org_types выбранной организации (farmer/mpk/...)
  membershipLevel: string | null
  applicationStatus: string | null  // последняя membership_applications.status (submitted/under_review/approved/rejected)
  // ARS-361: единый read-model членства + верификации. null означает, что новый RPC
  // недоступен/вернул несовместимый ответ; consumers обязаны fail closed по verification.
  membershipVerification: OrgMembershipVerificationReadModel | null
  // Обратносуместимые поля для фермерского кабинета. Предпочитают ARS-361 read-model,
  // а при его недоступности сохраняют старый rpc_get_org_subscription fallback.
  subscriptionState: string | null
  currentPeriodEnd: string | null   // ISO — реальная дата «членство до» (не хардкод)
  nextBillingAt: string | null      // ISO — реальная дата следующего продления
}

async function resolveRegionName(regionId: string | null): Promise<string | null> {
  if (!regionId) return null
  const { data } = await supabase.from('regions').select('name_ru').eq('id', regionId).single()
  return (data as { name_ru: string } | null)?.name_ru ?? null
}

// Собирает профиль текущего аккаунта. preferType: какой тип организации показывать.
export async function loadAccountProfile(
  preferType: 'farmer' | 'mpk' = 'farmer'
): Promise<AccountProfile | null> {
  const ctx = await loadMyContext()
  if (!ctx) return null

  const org =
    ctx.organizations.find((o) => o.org_types.includes(preferType)) ??
    ctx.organizations.find((o) => o.is_primary) ??
    ctx.organizations[0] ??
    null

  const { data: userData } = await supabase.auth.getUser()
  const meta = userData?.user?.user_metadata as { full_name?: string; phone?: string; legal_form?: string } | undefined

  // Членство нужного типа (МПК-орг может иметь membership с org_type='mpk').
  const membership = org
    ? ctx.memberships.find((m) => m.organization_id === org.id && m.org_type === preferType)
      ?? ctx.memberships.find((m) => m.organization_id === org.id)
      ?? null
    : null

  // Последняя заявка на членство — для маппинга статуса в кабинете (pending/rejected).
  let applicationStatus: string | null = null
  if (org) {
    const { data: appData } = await supabase
      .from('membership_applications')
      .select('status')
      .eq('organization_id', org.id)
      .order('submitted_at', { ascending: false })
      .limit(1)
    applicationStatus = (appData?.[0] as { status: string } | undefined)?.status ?? null
  }

  // ARS-361: новый защищённый read-model — единственный источник статусов членства и
  // верификации для новых потребителей. При недоступном/старом RPC не ломаем текущий
  // кабинет: ниже останется совместимый fallback rpc_get_org_subscription.
  let membershipVerification: OrgMembershipVerificationReadModel | null = null
  if (org) {
    try {
      const { data, error } = await supabase.rpc('rpc_get_org_membership_verification', {
        p_organization_id: org.id,
      })
      if (error) {
        console.warn('loadAccountProfile: rpc_get_org_membership_verification error:', error)
      } else {
        membershipVerification = parseOrgMembershipVerificationReadModel(data)
      }
    } catch (error) {
      // В частности, защищаем UI при выкладке фронта раньше миграции RPC.
      console.warn('loadAccountProfile: rpc_get_org_membership_verification failed:', error)
    }
  }

  // ARS-263: legacy fallback для поверхностей, ещё ожидающих старый subscription RPC.
  // Он вызывается только когда ARS-361 read-model не получен/невалиден.
  let subscriptionState: string | null = null
  let currentPeriodEnd: string | null = null
  let nextBillingAt: string | null = null
  if (membershipVerification) {
    subscriptionState = membershipVerification.membership.state
    currentPeriodEnd = membershipVerification.membership.currentPeriodEnd
    nextBillingAt = membershipVerification.membership.nextBillingAt
  } else if (org) {
    const { data: subData } = await supabase.rpc('rpc_get_org_subscription', { p_organization_id: org.id })
    const sub = subData as { state?: string; current_period_end?: string | null; next_billing_at?: string | null } | null
    if (sub && sub.state) {
      subscriptionState = sub.state
      currentPeriodEnd = sub.current_period_end ?? null
      nextBillingAt = sub.next_billing_at ?? null
    }
  }

  return {
    userId: ctx.user_id,
    orgId: org?.id ?? null,
    name: org?.legal_name ?? null,
    bin: org?.bin_iin ?? null,
    district: await resolveRegionName(org?.region_id ?? null),
    ownerName: meta?.full_name ?? null,
    legalForm: meta?.legal_form ?? null,
    // ВАЖНО: || а не ?? — userData.user.phone приходит пустой строкой "",
    // а ?? её не пропускает (falls through только на null/undefined). С ?? телефон
    // резолвился в "" и кабинет показывал демо-номер. С || пустые строки пропускаются.
    phone: org?.phone || userData?.user?.phone || meta?.phone || null,
    orgTypes: org?.org_types ?? [],
    membershipLevel: membership?.level ?? null,
    applicationStatus,
    membershipVerification,
    subscriptionState,
    currentPeriodEnd,
    nextBillingAt,
  }
}

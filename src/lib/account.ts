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

// Читает контекст текущего пользователя. null = не авторизован / нет данных / бэкенд недоступен.
export async function loadMyContext(): Promise<MyContext | null> {
  const { data, error } = await supabase.rpc('rpc_get_my_context')
  if (error || !data) return null
  const ctx = data as Partial<MyContext>
  if (!ctx.user_id) return null
  return {
    user_id: ctx.user_id,
    // Нормализуем org_types: задеплоенный rpc_get_my_context может возвращать
    // либо org_types (массив, версия из d01_kernel.sql), либо org_type (строка,
    // более старая версия в БД). Без этого o.org_types.includes(...) в
    // loadAccountProfile падал с TypeError → профиль null → кабинет уходил в демо.
    // ДЕФЕКТ (SQL≠деплой): выровнять задеплоенный RPC под d01 (org_types массив).
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
  phone: string | null
  orgTypes: string[]           // org_types выбранной организации (farmer/mpk/...)
  membershipLevel: string | null
  applicationStatus: string | null  // последняя membership_applications.status (submitted/under_review/approved/rejected)
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
  const meta = userData?.user?.user_metadata as { full_name?: string; phone?: string } | undefined

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

  return {
    userId: ctx.user_id,
    orgId: org?.id ?? null,
    name: org?.legal_name ?? null,
    bin: org?.bin_iin ?? null,
    district: await resolveRegionName(org?.region_id ?? null),
    ownerName: meta?.full_name ?? null,
    // ВАЖНО: || а не ?? — userData.user.phone приходит пустой строкой "",
    // а ?? её не пропускает (falls through только на null/undefined). С ?? телефон
    // резолвился в "" и кабинет показывал демо-номер. С || пустые строки пропускаются.
    phone: org?.phone || userData?.user?.phone || meta?.phone || null,
    orgTypes: org?.org_types ?? [],
    membershipLevel: membership?.level ?? null,
    applicationStatus,
  }
}

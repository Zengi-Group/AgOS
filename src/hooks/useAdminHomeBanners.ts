import { useRpc, useRpcMutation } from '@/hooks/useRpc'

// Строка таблицы home_banners (см. Docs/AGOS-Slice-AppBanners.md · d10_public_site.sql §8).
export interface HomeBanner {
  id: string
  app: 'farmer' | 'mpk'
  title: string
  subtitle: string | null
  kicker: string | null
  image_path: string | null
  icon: string | null
  tone: 'gold' | 'green' | 'neutral'
  action_type: 'internal' | 'external' | 'none'
  action_target: string | null
  membership_variant: 'all' | 'season' | 'campaign' | 'join'
  sort_order: number
  active_from: string | null
  active_until: string | null
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface SaveHomeBannerInput {
  p_id?: string | null
  p_app: string
  p_title: string
  p_subtitle?: string | null
  p_kicker?: string | null
  p_image_path?: string | null
  p_icon?: string | null
  p_tone?: string
  p_action_type?: string
  p_action_target?: string | null
  p_membership_variant?: string
  p_sort_order?: number
  p_active_from?: string | null
  p_active_until?: string | null
  p_is_active?: boolean
}

const LIST_KEY = ['admin_list_home_banners']

/** Admin list всех баннеров (опц. фильтр по app). RPC admin_list_home_banners (guard expert/admin). */
export function useAdminHomeBanners(app?: 'farmer' | 'mpk') {
  return useRpc<HomeBanner[]>('admin_list_home_banners', { p_app: app ?? null })
}

/** Upsert баннера (id NULL → insert). RPC admin_save_home_banner. */
export function useSaveHomeBanner() {
  return useRpcMutation<SaveHomeBannerInput, HomeBanner>('admin_save_home_banner', {
    invalidateKeys: [LIST_KEY],
    successMessage: 'Баннер сохранён',
  })
}

/** Переключение is_active. RPC admin_toggle_home_banner. */
export function useToggleHomeBanner() {
  return useRpcMutation<{ p_id: string; p_is_active: boolean }, HomeBanner>('admin_toggle_home_banner', {
    invalidateKeys: [LIST_KEY],
  })
}

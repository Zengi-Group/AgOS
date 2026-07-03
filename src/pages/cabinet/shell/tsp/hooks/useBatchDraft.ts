// AgOS · TSP-1 · Персист черновика визарда: session-скоуп платформенного адаптера
// (web = sessionStorage; нативка (S4) = Preferences — form preservation по Dok6).

import { draftStorage } from '@/platform/storage'
import { FRESH_WIZ, type WizState } from '../types/batch'

const DRAFT_KEY = 'agos.tsp.draft.v1'

export function useBatchDraft() {
  const load = (): WizState => {
    try {
      const s = draftStorage.getItem(DRAFT_KEY)
      if (s) {
        const parsed = JSON.parse(s) as Partial<WizState>
        // catLoading сбрасываем — не хотим висящего спиннера при восстановлении
        return { ...FRESH_WIZ, ...parsed, catLoading: false }
      }
    } catch { /* ignore */ }
    return { ...FRESH_WIZ }
  }

  const save = (w: WizState) => {
    try { draftStorage.setItem(DRAFT_KEY, JSON.stringify(w)) } catch { /* ignore */ }
  }

  const clear = () => {
    try { draftStorage.removeItem(DRAFT_KEY) } catch { /* ignore */ }
  }

  return { load, save, clear }
}

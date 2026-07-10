// AgOS · ARS-212 · Персист черновика мастера фермы (образец useBatchDraft): платформенный
// адаптер draftStorage (web = sessionStorage; нативка = Preferences). Черновик сохраняется
// после каждого ответа (P11) — выход/возврат не теряют введённое.

import { draftStorage } from '@/platform/storage'
import { FRESH_FW, type FwState } from '../types'

const DRAFT_KEY = 'agos.farm.wizard.draft.v1'

export function useFarmDraft() {
  const load = (): FwState => {
    try {
      const s = draftStorage.getItem(DRAFT_KEY)
      if (s) {
        const parsed = JSON.parse(s) as Partial<FwState>
        return { ...FRESH_FW, ...parsed, heads: { ...FRESH_FW.heads, ...(parsed.heads || {}) } }
      }
    } catch { /* ignore */ }
    return { ...FRESH_FW, heads: { ...FRESH_FW.heads } }
  }

  const save = (w: FwState) => {
    try { draftStorage.setItem(DRAFT_KEY, JSON.stringify(w)) } catch { /* ignore */ }
  }

  const clear = () => {
    try { draftStorage.removeItem(DRAFT_KEY) } catch { /* ignore */ }
  }

  return { load, save, clear }
}

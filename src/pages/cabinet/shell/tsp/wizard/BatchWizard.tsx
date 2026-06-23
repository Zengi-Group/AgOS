// AgOS · TSP-1 · Оркестратор визарда «Новая партия» (p1/wizard.jsx + ТЗ TSP-1, часть 4).
// Состояние черновика — sessionStorage; публикация — RPC rpc_create_batch.

import { useCallback, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useShell } from '../../context'
import { FRESH_WIZ, type Batch, type PubVariant, type WizState } from '../types/batch'
import { fmtD, fmtDGen, publishInfo, wizWindow } from '../data/tsp-utils'
import { useBatchDraft } from '../hooks/useBatchDraft'
import { WizStep1Animals } from './WizStep1Animals'
import { WizStep2Window } from './WizStep2Window'
import { WizStep3Category } from './WizStep3Category'
import { WizStep4Price } from './WizStep4Price'
import { WizStep5Review } from './WizStep5Review'

interface BatchWizardProps {
  onDone: (batch: Batch, variant: PubVariant) => void
  onExit: () => void
  onTuran?: () => void
  initialStep?: number
  initialWiz?: Partial<WizState>
}

// Собрать партию локально, когда backend (rpc_create_batch) недоступен.
// Позволяет концепту работать офлайн: опубликованная партия появляется в кабинете.
function buildLocalBatch(w: WizState, price: number, delayed: boolean, at: Date | null): Batch {
  const today = new Date()
  const created = { t: 'Создана', d: fmtD(today) }
  const atLabel = at ? fmtDGen(at) : ''
  const history = delayed
    ? [created, { t: 'Запланирована публикация на ' + atLabel, d: fmtD(today) }]
    : [created, { t: 'Выставлена на продажу', d: fmtD(today) }, { t: 'Отправлена покупателям', d: fmtD(today) }]
  return {
    id: 'local-' + Date.now().toString(36),
    cat: w.catKey ?? undefined,
    breed: w.breed,
    heads: w.heads,
    avgWeight: w.avgWeight,
    age: w.age,
    fatness: w.fatness,
    district: w.district,
    price,
    dealPrice: null,
    state: delayed ? 'scheduled' : 'offering',
    ...(delayed ? { publishAtLabel: atLabel } : { deadlineLabel: 'завтра, 14:30' }),
    history,
  }
}

export function BatchWizard({ onDone, onExit, onTuran, initialStep, initialWiz }: BatchWizardProps) {
  const ctx = useShell()
  const { load, save, clear } = useBatchDraft()
  const [w, setW] = useState<WizState>(() => {
    const loaded = load()
    return {
      ...FRESH_WIZ,
      ...(initialWiz || {}),
      ...loaded,
      step: (initialStep || loaded.step || 1) as WizState['step'],
    }
  })
  const [isSubmitting, setIsSubmitting] = useState(false)

  const sw = useCallback((patch: Partial<WizState>) => {
    setW((prev) => {
      const next = { ...prev, ...patch }
      save(next)
      return next
    })
  }, [save])

  const goNext = () => sw({ step: (w.step + 1) as WizState['step'] })
  const goBack = () => {
    if (w.step === 1) { onExit(); return }
    if (w.step === 3) sw({ step: 2, catKey: null, catUnknown: false, catLoading: false })
    else sw({ step: (w.step - 1) as WizState['step'] })
  }
  const goto = (step: number) => sw({ step: step as WizState['step'] })
  const handleExit = () => { onExit() }

  const handlePublish = async () => {
    setIsSubmitting(true)
    try {
      const win = wizWindow(w)!
      const pi = publishInfo(win)
      const price = parseInt(w.price, 10)
      const delayed = pi?.delayed ?? false
      const at: Date | null = pi && pi.delayed ? (pi.at ?? null) : null

      let batch: Batch
      try {
        const { data, error } = await supabase.rpc('rpc_create_batch', {
          p_cat:         w.catKey,
          p_breed:       w.breed,
          p_heads:       w.heads,
          p_avg_weight:  w.avgWeight,
          p_age:         w.age,
          p_fatness:     w.fatness,
          p_district:    w.district,
          p_price:       price,
          p_window_from: win.from.toISOString().slice(0, 10),
          p_window_to:   win.to.toISOString().slice(0, 10),
          p_scheduled:   delayed,
        })
        if (error) throw error
        batch = data as Batch

        // Авто-матч по цене (D-AUTOMATCH-01): сразу после публикации система ищет
        // подходящий пул МПК (категория + цена совпадают) и матчит партию. Нет
        // подходящего пула — партия остаётся опубликованной. Контакты НЕ
        // раскрываются (D40 — только при executing). Сбой автоматча не ломает
        // публикацию: партия уже создана, оставляем как есть.
        try {
          const { data: m } = await supabase.rpc('rpc_self_auto_match_batch', {
            p_batch_id: (batch as { id: string }).id,
          })
          const match = m as { matched?: boolean; dealPrice?: number } | null
          if (match?.matched) {
            batch = { ...batch, state: 'matched', dealPrice: match.dealPrice ?? batch.dealPrice }
          }
        } catch (matchErr) {
          console.warn('rpc_self_auto_match_batch недоступен, пропускаем автоматч:', matchErr)
        }
      } catch (rpcErr) {
        // Нет backend (схема не задеплоена / офлайн) — собираем партию локально,
        // чтобы публикация работала в демо. RPC отработает, когда backend появится.
        console.warn('rpc_create_batch недоступен, публикуем локально:', rpcErr)
        batch = buildLocalBatch(w, price, delayed, at)
      }

      clear()

      // В MVP вариант определяет фронт (TSP-4: вернёт бэк): D если отложено, иначе B.
      const variant: PubVariant = delayed ? 'D' : 'B'
      onDone(batch, variant)
    } catch (err) {
      ctx.toast('Ошибка публикации')
      console.error(err)
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleSaveDraft = () => { onExit() }

  switch (w.step) {
    case 1: return <WizStep1Animals w={w} sw={sw} onNext={goNext} onBack={goBack} onExit={handleExit} />
    case 2: return <WizStep2Window w={w} sw={sw} onNext={goNext} onBack={goBack} onExit={handleExit} />
    case 3: return <WizStep3Category w={w} sw={sw} onNext={goNext} onBack={goBack} onExit={handleExit}
      onTuran={() => { (onTuran || onExit)() }} />
    case 4: return <WizStep4Price w={w} sw={sw} onNext={goNext} onBack={goBack} onExit={handleExit} />
    case 5: return <WizStep5Review w={w} onPublish={handlePublish} onSaveDraft={handleSaveDraft}
      onBack={goBack} onExit={handleExit} goto={goto} isSubmitting={isSubmitting} />
    default: return null
  }
}

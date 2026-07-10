// AgOS · ARS-212 · Оркестратор мастера профиля фермы: ветка, ярусный прогресс, draft-персист,
// выход/резюм, записи в БД (аддитивно через существующие RPC, HS-1/5). Рендерится ВНУТРИ внешнего
// <IonPage className="agos-flow-page"> (CabinetApp.renderFarm, slide-up, как BatchWizard).
//
// Флоу (step-map v2.1): F1 состав → F2 Payoff-1 → ярус «План» (отёл?·молодняк?·содержание) →
// порог? F6→F7 : F7. Записи best-effort (черновик всегда сохранён локально, P11).

import { useCallback, useEffect, useMemo, useState } from 'react'
import { useShell } from '../../context'
import {
  branchSteps, thresholdReached,
  type FwState, type FwStep, type CalvingAnswer, type YoungAnswer, type HousingAnswer,
} from '../types'
import { useFarmDraft } from '../hooks/useFarmDraft'
import {
  loadFarmCtx, ensureFarm, saveHerdAndArchetype, saveFarmField, generatePlan, type FarmCtx,
} from '../data/farm-profile'
import { FwStepHerd } from './FwStepHerd'
import { FwPayoffPrices } from './FwPayoffPrices'
import { FwStepCalving } from './FwStepCalving'
import { FwStepYoung } from './FwStepYoung'
import { FwStepHousing } from './FwStepHousing'
import { FwResult } from './FwResult'

type Screen = 'herd' | 'payoff' | 'step' | 'result'

interface Props {
  startAt: 'herd' | 'plan'   // F0a → herd; F0b resume-CTA → plan (ярус 2)
  onExit: () => void         // закрыть флоу → F0b
  onSell?: (catKey: string) => void  // «Продать через TURAN» (только членам)
}

export function FarmWizard({ startAt, onExit, onSell }: Props) {
  const { toast, farmRegion } = useShell()
  const { load, save } = useFarmDraft()

  const [w, setW] = useState<FwState>(() => load())
  const [ctx, setCtx] = useState<FarmCtx | null>(null)
  const [prefilled, setPrefilled] = useState(false)
  const [screen, setScreen] = useState<Screen>(startAt === 'plan' ? 'step' : 'herd')
  // Resume (F0b «Ещё N вопросов») → ярус 2 с первого неотвеченного вопроса ветки (по черновику).
  const [stepIdx, setStepIdx] = useState<number>(() => {
    if (startAt !== 'plan') return 0
    const b = branchSteps(w.heads)
    for (let i = 0; i < b.length; i++) {
      const s = b[i]
      const empty = s === 'calving' ? w.calving === '' : s === 'young' ? w.young === '' : w.housing === ''
      if (empty) return i
    }
    return 0
  })

  // Загрузка контекста фермы + предзаполнение стада из БД (rpc_get_farm_summary), если черновик пуст.
  useEffect(() => {
    let alive = true
    loadFarmCtx().then((c) => {
      if (!alive || !c) return
      setCtx(c)
      const draftEmpty = (Object.values(w.heads) as number[]).every((n) => !n)
      if (c.hasHerd && draftEmpty) {
        setPrefilled(true)
        setW((prev) => ({
          ...prev,
          heads: { ...prev.heads, ...c.heads },
          calving: prev.calving || c.calving,
          housing: prev.housing || c.housing,
        }))
      }
    })
    return () => { alive = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const sw = useCallback((patch: Partial<FwState>) => {
    setW((prev) => { const next = { ...prev, ...patch }; save(next); return next })
  }, [save])
  const setHeads = useCallback((patch: Partial<FwState['heads']>) => {
    setW((prev) => { const next = { ...prev, heads: { ...prev.heads, ...patch } }; save(next); return next })
  }, [save])

  const branch = useMemo<FwStep[]>(() => branchSteps(w.heads), [w.heads])
  const region = ctx?.region ?? farmRegion ?? null

  // ---- записи (best-effort) ----
  const persistHerd = async () => {
    if (!ctx) return
    const farmId = await ensureFarm(ctx)
    if (farmId && ctx.organizationId) {
      if (!ctx.farmId) setCtx({ ...ctx, farmId })
      await saveHerdAndArchetype(ctx.organizationId, farmId, w.heads)
    }
  }
  const persistFarmField = (patch: Parameters<typeof saveFarmField>[2]) => {
    if (ctx?.organizationId && ctx.farmId) saveFarmField(ctx.organizationId, ctx.farmId, patch)
  }

  const exitSaved = () => { toast('Сохранено — продолжите когда удобно'); onExit() }

  // ---- переходы ----
  const herdNext = () => { persistHerd(); setScreen('payoff') }
  const bridgeToPlan = () => { setStepIdx(0); setScreen('step') }

  const advanceStep = () => {
    if (stepIdx < branch.length - 1) setStepIdx(stepIdx + 1)
    else setScreen('result')
  }
  const stepBack = () => {
    if (stepIdx > 0) setStepIdx(stepIdx - 1)
    else setScreen('payoff')
  }

  const curStep = branch[stepIdx]
  const progress = { count: branch.length, step: stepIdx + 1 }
  const dots = branch.length > 1

  // Первый неотвеченный вопрос ветки (для «Ответить сейчас» из финала).
  const firstUnanswered = (): number => {
    for (let i = 0; i < branch.length; i++) {
      const s = branch[i]
      const empty = s === 'calving' ? w.calving === '' : s === 'young' ? w.young === '' : w.housing === ''
      if (empty) return i
    }
    return 0
  }
  const hasUnanswered = branch.some((s) =>
    s === 'calving' ? w.calving === '' : s === 'young' ? w.young === '' : w.housing === '')

  // ---- рендер ----
  if (screen === 'herd') {
    return <FwStepHerd heads={w.heads} setHeads={setHeads} prefilled={prefilled} onNext={herdNext} onExit={exitSaved} />
  }

  if (screen === 'payoff') {
    return (
      <FwPayoffPrices
        heads={w.heads}
        region={region}
        planQuestions={branch.length}
        onBridge={bridgeToPlan}
        onExit={exitSaved}
        onSell={onSell}
      />
    )
  }

  if (screen === 'result') {
    return (
      <FwResult
        generating={thresholdReached(w)}
        onGenerate={async () => {
          if (ctx?.organizationId && ctx.farmId) await generatePlan(ctx.organizationId, ctx.farmId, w.calvingMonth)
        }}
        hasUnanswered={hasUnanswered}
        onToFarm={onExit}
        onAnswerNow={() => { setStepIdx(firstUnanswered()); setScreen('step') }}
      />
    )
  }

  // screen === 'step' — ярус «План» по ветке
  const willBuildPlan = thresholdReached(w)
  if (curStep === 'calving') {
    return (
      <FwStepCalving
        progress={progress}
        dots={dots}
        value={w.calving}
        month={w.calvingMonth}
        setValue={(v: CalvingAnswer) => sw({ calving: v })}
        setMonth={(m) => sw({ calvingMonth: m })}
        onNext={() => { persistFarmField({ calving: w.calving, calvingMonth: w.calvingMonth }); advanceStep() }}
        onSkip={() => { sw({ calving: '', calvingMonth: null }); advanceStep() }}
        onBack={stepBack}
        onExit={exitSaved}
      />
    )
  }
  if (curStep === 'young') {
    return (
      <FwStepYoung
        progress={progress}
        dots={dots}
        value={w.young}
        setValue={(v: YoungAnswer) => sw({ young: v })}
        onNext={() => { persistFarmField({ young: w.young }); advanceStep() }}
        onSkip={() => { sw({ young: '' }); advanceStep() }}
        onBack={stepBack}
        onExit={exitSaved}
      />
    )
  }
  // housing
  return (
    <FwStepHousing
      progress={progress}
      dots={dots}
      value={w.housing}
      willBuildPlan={willBuildPlan}
      setValue={(v: HousingAnswer) => sw({ housing: v })}
      onNext={() => { persistFarmField({ housing: w.housing }); advanceStep() }}
      onSkip={() => { sw({ housing: '' }); advanceStep() }}
      onBack={stepBack}
      onExit={exitSaved}
    />
  )
}

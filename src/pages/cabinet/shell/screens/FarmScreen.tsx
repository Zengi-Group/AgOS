// AgOS · ARS-212 · Таб «Ферма» (замена PlaceholderScreen на роуте /cabinet/farm).
// SCR-F0a · Хук (профиль пуст): hero + CTA «Рассказать про стадо».
// SCR-F0b · Resume (состав есть, плана нет): сводка стада + resume-CTA + «Поправить состав».
// State C · План есть (ARS-215): годовой план (draft-ЦТК) + фазы + сводка стада — payoff Узла 1.
// Каркас — IonShellFrame + TabHead (у shell свой заголовок, Topbar-принцип не применяется).

import { useCallback, useEffect, useState } from 'react'
import { IonShellFrame } from '../components/IonShellFrame'
import { TabHead } from '../components/TabHead'
import { PhIcon } from '../components/icons/PhIcon'
import { MkCta } from '../tsp/components/MkCta'
import { HERD_FIELDS, branchSteps, type HerdKey } from '../farm/types'
import { loadFarmCtx, loadFarmPlan, type FarmCtx, type FarmPlan } from '../farm/data/farm-profile'
import { ScreenSkeleton } from '../components/ScreenSkeleton'

interface Props {
  onStart: () => void    // F0a CTA / «Поправить состав» → мастер с F1 (prefill)
  onResume: () => void   // F0b resume-CTA → мастер, ярус 2
}

export function FarmScreen({ onStart, onResume }: Props) {
  const [ctx, setCtx] = useState<FarmCtx | null>(null)
  const [plan, setPlan] = useState<FarmPlan | null>(null)
  const [loading, setLoading] = useState(true)

  // Этап 2 · D3: загрузка вынесена в reload — переиспользуется pull-to-refresh
  // (единственный экран данных, у которого раньше не было НИ PTR, НИ поллинга).
  // silent=true — тихое обновление без скелета поверх живого контента (паттерн C5).
  const reload = useCallback(async (opts?: { silent?: boolean }) => {
    if (!opts?.silent) setLoading(true)
    // План читается после ctx (нужны org/farm id) — state C приоритетнее F0b (ARS-215).
    const c = await loadFarmCtx()
    setCtx(c)
    setPlan(c?.organizationId && c.farmId ? await loadFarmPlan(c.organizationId, c.farmId) : null)
    setLoading(false)
  }, [])

  useEffect(() => {
    let alive = true
    reload().catch(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [reload])

  const heads = ctx?.heads ?? { cows: 0, calves: 0, heifers: 0, steers: 0, bull: 0 }
  const total = (Object.values(heads) as number[]).reduce((s, n) => s + n, 0)
  const hasHerd = ctx?.hasHerd ?? false

  return (
    <IonShellFrame label="Ферма" onRefresh={() => reload({ silent: true })}>
      <TabHead title="Ферма" />
      <div className="mk">
        {loading && !ctx ? (
          <ScreenSkeleton variant="farm" />
        ) : plan ? (
          // ── State C · План есть (ARS-215) ──
          <FarmPlanView plan={plan} heads={heads} total={total} onEdit={onStart} />
        ) : !hasHerd ? (
          // ── SCR-F0a · Хук ──
          <div className="es fw-hook">
            <div className="es-art"><PhIcon name="cow" size={46} /></div>
            <div className="fw-hook-t">Расскажите, кто у вас в стаде</div>
            <div className="fw-hook-s">Покажем, что почём сейчас продаётся, и соберём план работ на год</div>
            <div className="es-act">
              <MkCta onClick={onStart}>Рассказать про стадо</MkCta>
              <div className="mk-note">≈ 3 минуты · можно прерваться — всё сохранится</div>
            </div>
          </div>
        ) : (
          // ── SCR-F0b · Resume ──
          <FarmResume heads={heads} total={total} onResume={onResume} onEdit={onStart} />
        )}
      </div>
    </IonShellFrame>
  )
}

// Сводка стада (общий блок F0b + state C, P4).
function HerdBox({ heads }: { heads: Record<HerdKey, number> }) {
  const rows = HERD_FIELDS.filter((f) => heads[f.key] > 0)
  return (
    <div className="fw-herd-box">
      {rows.map((f) => (
        <div className="fw-herd-row" key={f.key}>
          <span className="fw-herd-n">{f.label}</span>
          <span className="fw-herd-h mk-mono">{heads[f.key]}</span>
        </div>
      ))}
    </div>
  )
}

function FarmResume({ heads, total, onResume, onEdit }: {
  heads: Record<HerdKey, number>; total: number; onResume: () => void; onEdit: () => void
}) {
  const branch = branchSteps(heads)
  const canPlan = heads.cows > 0  // cow_calf/combined → план строится; иначе finishing/прочее
  const n = branch.length
  const qWord = n === 1 ? 'вопрос' : n < 5 ? 'вопроса' : 'вопросов'

  return (
    <>
      <div className="fw-herd-eyebrow">ВАШЕ СТАДО · {total} ГОЛОВ</div>
      <HerdBox heads={heads} />
      {canPlan ? (
        <>
          <MkCta onClick={onResume}>{`Ещё ${n} ${qWord} — план работ`}</MkCta>
          <button className="mk-link" onClick={onEdit}>Поправить состав стада</button>
        </>
      ) : (
        <>
          <div className="fw-herd-note">Цены по вашему стаду — на Главной и в «Рынке»</div>
          <button className="mk-link" onClick={onEdit}>Поправить состав стада</button>
        </>
      )}
    </>
  )
}

// ── State C · Показ плана (ARS-215) ──
// Данные = payload rpc_get_production_plan (FARM-01/ARS-214). Дизайн: плоские карты r-12,
// один акцент на блок — амбер-чип только у активной фазы; цифры/даты в mk-mono (R-9).

const PHASE_CHIP: Record<string, { label: string; cls: string }> = {
  active:    { label: 'идёт',      cls: ' on' },
  upcoming:  { label: 'впереди',   cls: '' },
  completed: { label: 'готово',    cls: ' ok' },
  skipped:   { label: 'пропущена', cls: '' },
}

const fmtDate = (d: string) => new Date(d).toLocaleDateString('ru-RU')
const fmtDayMonth = (d: string) => new Date(d).toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' })

function FarmPlanView({ plan, heads, total, onEdit }: {
  plan: FarmPlan; heads: Record<HerdKey, number>; total: number; onEdit: () => void
}) {
  return (
    <>
      <div className="fw-herd-eyebrow">ПЛАН РАБОТ НА ГОД</div>
      <div className="fw-plan-card">
        <div className="fw-plan-head">
          <div>
            <div className="fw-plan-name">{plan.plan_name}</div>
            <div className="fw-plan-period mk-mono">
              {fmtDate(plan.start_date)}{plan.end_date ? ` — ${fmtDate(plan.end_date)}` : ''}
            </div>
          </div>
          {plan.status === 'draft' && <span className="fw-plan-chip">Черновик</span>}
        </div>
      </div>
      {plan.phases.length > 0 ? (
        <div className="fw-plan-box">
          {plan.phases.map((ph) => {
            const chip = PHASE_CHIP[ph.status] ?? { label: ph.status, cls: '' }
            return (
              <div className="fw-ph" key={ph.phase_id}>
                <div>
                  <div className="fw-ph-n">
                    {ph.is_sale_phase && <PhIcon name="tag" size={13} />}
                    {ph.name}
                  </div>
                  <div className="fw-ph-d">
                    <span className="mk-mono">{fmtDayMonth(ph.start_date)} — {fmtDayMonth(ph.end_date)}</span>
                    {ph.task_counts.total > 0 && (
                      <> · <span className="mk-mono">{ph.task_counts.completed}/{ph.task_counts.total}</span> задач</>
                    )}
                  </div>
                </div>
                <span className={`fw-ph-chip${chip.cls}`}>{chip.label}</span>
              </div>
            )
          })}
        </div>
      ) : (
        // R4: шаблон типа хозяйства ещё не наполнен фазами (combined) — план есть, работы позже.
        <div className="fw-herd-note">Работы по месяцам появятся здесь — мы дополняем план под ваш тип хозяйства</div>
      )}
      <div className="fw-herd-eyebrow">ВАШЕ СТАДО · {total} ГОЛОВ</div>
      <HerdBox heads={heads} />
      <button className="mk-link" onClick={onEdit}>Поправить состав стада</button>
    </>
  )
}

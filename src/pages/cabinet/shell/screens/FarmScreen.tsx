// AgOS · ARS-212 · Таб «Ферма» (замена PlaceholderScreen на роуте /cabinet/farm).
// SCR-F0a · Хук (профиль пуст): hero + CTA «Рассказать про стадо».
// SCR-F0b · Resume (состав есть, плана нет): сводка стада + resume-CTA + «Поправить состав».
// Каркас — IonShellFrame + TabHead (у shell свой заголовок, Topbar-принцип не применяется).
// Состояние плана (state C) — ARS-215, вне слайса: cow_calf/combined всегда показывает resume-CTA.

import { useEffect, useState } from 'react'
import { IonShellFrame } from '../components/IonShellFrame'
import { TabHead } from '../components/TabHead'
import { PhIcon } from '../components/icons/PhIcon'
import { MkCta } from '../tsp/components/MkCta'
import { HERD_FIELDS, branchSteps, type HerdKey } from '../farm/types'
import { loadFarmCtx, type FarmCtx } from '../farm/data/farm-profile'
import { SkeletonBlocks } from '../components/SkeletonBlocks'

interface Props {
  onStart: () => void    // F0a CTA / «Поправить состав» → мастер с F1 (prefill)
  onResume: () => void   // F0b resume-CTA → мастер, ярус 2
}

export function FarmScreen({ onStart, onResume }: Props) {
  const [ctx, setCtx] = useState<FarmCtx | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let alive = true
    loadFarmCtx().then((c) => { if (alive) { setCtx(c); setLoading(false) } })
    return () => { alive = false }
  }, [])

  const heads = ctx?.heads ?? { cows: 0, calves: 0, heifers: 0, steers: 0, bull: 0 }
  const total = (Object.values(heads) as number[]).reduce((s, n) => s + n, 0)
  const hasHerd = ctx?.hasHerd ?? false

  return (
    <IonShellFrame label="Ферма">
      <TabHead title="Ферма" />
      <div className="mk">
        {loading ? (
          <SkeletonBlocks n={3} />
        ) : !hasHerd ? (
          // ── SCR-F0a · Хук ──
          <div className="es fw-hook">
            <div className="es-art"><PhIcon name="cow" size={46} /></div>
            <div className="fw-hook-t">Расскажите, кто у вас в стаде</div>
            <div className="fw-hook-s">Покажем, что почём сейчас продаётся, и соберём план работ на год</div>
            <div className="es-act">
              <MkCta onClick={onStart}>Рассказать про стадо</MkCta>
              <div className="mk-note mk-mono">≈ 3 минуты · можно прерваться — всё сохранится</div>
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

function FarmResume({ heads, total, onResume, onEdit }: {
  heads: Record<HerdKey, number>; total: number; onResume: () => void; onEdit: () => void
}) {
  const rows = HERD_FIELDS.filter((f) => heads[f.key] > 0)
  const branch = branchSteps(heads)
  const canPlan = heads.cows > 0  // cow_calf/combined → план строится; иначе finishing/прочее
  const n = branch.length
  const qWord = n === 1 ? 'вопрос' : n < 5 ? 'вопроса' : 'вопросов'

  return (
    <>
      <div className="fw-herd-eyebrow mk-mono">ВАШЕ СТАДО · {total} ГОЛОВ</div>
      <div className="fw-herd-box">
        {rows.map((f) => (
          <div className="fw-herd-row" key={f.key}>
            <span className="fw-herd-n">{f.label}</span>
            <span className="fw-herd-h mk-mono">{heads[f.key]}</span>
          </div>
        ))}
      </div>
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

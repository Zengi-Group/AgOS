// AgOS · ARS-212 · Таб «Ферма» (замена PlaceholderScreen на роуте /cabinet/farm).
// SCR-F0a · Хук (профиль пуст): hero + CTA «Рассказать про стадо».
// SCR-F0b · Resume (состав есть, плана нет): сводка стада + resume-CTA + «Поправить состав».
// State C · План есть (ARS-215): годовой план (draft-ЦТК) + фазы + сводка стада — payoff Узла 1.
// Каркас — IonShellFrame + TabHead (у shell свой заголовок, Topbar-принцип не применяется).
//
// ARS-280 (Ферма 2.0 · F4) · Каркас модуля: пока стада нет — полноэкранный хук (табы не
// показываем, ARS-212 first-run без изменений); как только есть состав/план — верхние табы
// Обзор·Задачи·Стадо·Ещё (дефолт Обзор), паттерн `.mk-tabs` Рынка (Slice8 §0/§1). Обзор пока
// держит существующий контент (план ARS-215 / resume F0b) — SCR-OV строит F5; Стадо — заглушка
// (F9). Ещё (§6) — профиль + корма, «Поправить состав» достижим (HS-2).
// ARS-284 (F8): полноценный SCR-TA·Год (TasksScreen) заменил временный мост FarmPlanView —
// карточки фаз/чипы статуса переехали туда же (визуальный reuse, HS-2); plan здесь остаётся
// (гейт `empty` ниже всё ещё смотрит на него — F0a показывается, пока нет ни стада, ни плана).

import { useCallback, useEffect, useState } from 'react'
import { IonShellFrame } from '../components/IonShellFrame'
import { TabHead } from '../components/TabHead'
import { PhIcon } from '../components/icons/PhIcon'
import { MkCta } from '../tsp/components/MkCta'
import { HERD_FIELDS, type HerdKey } from '../farm/types'
import { loadFarmCtx, loadFarmPlan, type FarmCtx, type FarmPlan } from '../farm/data/farm-profile'
import { FARM_TABS, type FarmTab, type FarmTabParams, type GoFarmTab } from '../farm/tabs'
import { OverviewScreen } from '../farm/OverviewScreen'
import { TasksScreen } from '../farm/TasksScreen'
import { ScreenSkeleton } from '../components/ScreenSkeleton'

interface Props {
  onStart: () => void    // F0a CTA / «Поправить состав» → мастер с F1 (prefill)
  onResume: () => void   // F0b resume-CTA → мастер, ярус 2
  toast: (text: string) => void
}

export function FarmScreen({ onStart, onResume, toast }: Props) {
  const [ctx, setCtx] = useState<FarmCtx | null>(null)
  const [plan, setPlan] = useState<FarmPlan | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshNonce, setRefreshNonce] = useState(0)  // PTR-триггер для SCR-OV (F5)

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

  // F4 · активный верхний таб + параметры перехода. goFarmTab — единый внутримодульный вызов
  // (Slice8 §1.1): в F4 его дёргает таб-бар; параметры несёт состояние и читают тела F5–F9.
  const [active, setActive] = useState<{ tab: FarmTab; params?: FarmTabParams }>({ tab: 'overview' })
  const goFarmTab = useCallback<GoFarmTab>((tab, params) => setActive({ tab, params }), [])

  // Полный refetch модуля (Slice8 §7: сдвиг старта случки → ВСЕ кэш-юниты) — тот же эффект,
  // что у pull-to-refresh, но вызывается программно (ARS-284, после confirm в SCR-TA·Год).
  const bumpRefresh = useCallback(() => {
    setRefreshNonce((n) => n + 1)
    return reload({ silent: true })
  }, [reload])

  // Профиль пуст (нет ни стада, ни плана) → полноэкранный хук БЕЗ табов (ARS-212 first-run
  // без изменений). Табы появляются, как только есть состав/план.
  const empty = !plan && !hasHerd

  return (
    <IonShellFrame label="Ферма" onRefresh={bumpRefresh}>
      <TabHead title="Ферма" />
      <div className="mk">
        {loading && !ctx ? (
          <ScreenSkeleton variant="farm" />
        ) : empty ? (
          // ── SCR-F0a · Хук (профиль пуст) ──
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
          // ── F4 · Каркас: верхние табы (дефолт Обзор), паттерн .mk-tabs Рынка (Slice8 §0) ──
          <>
            <div className="mk-tabs">
              {FARM_TABS.map((t) => (
                <button
                  key={t.key}
                  className={'mk-tab' + (active.tab === t.key ? ' on' : '')}
                  onClick={() => goFarmTab(t.key)}
                >
                  <span className="mk-tab-t">{t.label}</span>
                </button>
              ))}
            </div>
            {active.tab === 'overview' ? (
              // SCR-OV «Обзор» (F5, ARS-281) — 4 зоны + внимание + сегодня; один rpc_get_farm_overview.
              ctx?.organizationId && ctx.farmId ? (
                <OverviewScreen
                  orgId={ctx.organizationId}
                  farmId={ctx.farmId}
                  goFarmTab={goFarmTab}
                  onSetupPlan={onResume}
                  refreshNonce={refreshNonce}
                />
              ) : (
                <div className="fw-herd-note">Профиль загружается…</div>
              )
            ) : active.tab === 'tasks' ? (
              // SCR-TA «Задачи» (F6/F7/F8) — шапка (Неделя|Месяц|Год); Неделя (ARS-282), Месяц
              // (ARS-283, MonthScreen.tsx) и Год (ARS-284) все рабочие.
              ctx?.organizationId && ctx.farmId ? (
                <TasksScreen
                  orgId={ctx.organizationId}
                  farmId={ctx.farmId}
                  goFarmTab={goFarmTab}
                  params={active.params}
                  toast={toast}
                  onGlobalRefresh={bumpRefresh}
                  refreshNonce={refreshNonce}
                />
              ) : (
                <div className="fw-herd-note">Профиль загружается…</div>
              )
            ) : active.tab === 'herd' ? (
              <HerdSoon />
            ) : (
              <MoreTab heads={heads} total={total} onEditComposition={onStart} />
            )}
          </>
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

// ── F4 · Стадо — заглушка-шов (тело строит F9). Блоб-язык empty-state (R-6/R-24),
// без пунктирных рамок; иконка функциональная (PhIcon, R-2). ──
function HerdSoon() {
  return (
    <div className="mk-empty">
      <div className="mk-empty-art"><PhIcon name="cow" size={46} /></div>
      <div className="mk-empty-h">Стадо и обход скоро появятся</div>
      <div className="mk-empty-t">Группы стада и ежедневный обход — отметка и отклонения за пару касаний. Готовим этот экран.</div>
    </div>
  )
}

// ── F4 · Ещё (Slice8 §6): профиль хозяйства (сводка + «Поправить состав» → мастер ARS-212,
// обязательный путь HS-2) + корма-остатки (честное «не ведётся» до F12). ──
function MoreTab({ heads, total, onEditComposition }: {
  heads: Record<HerdKey, number>; total: number; onEditComposition: () => void
}) {
  return (
    <>
      <div className="fw-herd-eyebrow">ПРОФИЛЬ ХОЗЯЙСТВА · {total} ГОЛОВ</div>
      <HerdBox heads={heads} />
      <button className="mk-link" onClick={onEditComposition}>Поправить состав стада</button>
      <div className="fw-herd-eyebrow">КОРМА · ОСТАТКИ</div>
      <div className="fw-herd-note">Учёт остатков кормов пока не ведётся — появится в отдельном обновлении. Тогда покажем, на сколько дней хватает запаса.</div>
    </>
  )
}

// AgOS · Этап 2 · Главная — модель трёх ярусов (Вариант A). Источник истины — shell/home.jsx.
// Ярус 1 «ТРЕБУЕТ РЕШЕНИЯ» · Ярус 2 «ИДЁТ САМО» · Ярус 3 «БЫСТРЫЙ ДОСТУП».
// Ярусы 1 и 2 скрываются целиком, когда пусты. Ярус 3 есть всегда. Грид сервисов — ЯКОРЬ.

import { ruPlural } from '../data/fmt'
import { farmOpenTasks, type FarmState } from '../data/farm-seed'
import type { BannerCard, ServiceDef } from '../data/banners'
import type { DecisionCardModel, ObserveItemModel } from '../data/membership'
import type { StickerData } from '../data/prices'
import type { MembershipStatus, Route } from '../types'
import { ShellFrame } from '../components/ShellFrame'
import { HomeHead } from '../components/HomeHead'
import { HomeBanner } from '../components/HomeBanner'
import { ServiceGrid } from '../components/ServiceGrid'
import { TierHead } from '../components/TierHead'
import { DecisionCard } from '../components/DecisionCard'
import { ObserveCard } from '../components/ObserveCard'
import { AheadBlock } from '../components/AheadBlock'
import { SkeletonBlocks } from '../components/SkeletonBlocks'
import { ShIc } from '../components/icons/ShIc'

interface Props {
  membership: MembershipStatus
  farm: FarmState
  decisions: DecisionCardModel[]
  observe: ObserveItemModel[]
  bannerVariant: string
  sticker: StickerData
  loading: boolean
  onBanner: (c: BannerCard) => void
  openService: (s: ServiceDef) => void
  go: (r: Route) => void
}

export function HomeScreen({ membership, farm, decisions, observe, bannerVariant, sticker, loading, onBanner, openService, go }: Props) {
  const farmTasksN = farmOpenTasks(farm).length
  const quiet = decisions.length === 0 && observe.length <= 1
  const showAhead = quiet
  const farmOverdue = (farm.tasks || []).some((t) => t.overdue && !t.done && !t.dismissed)
  const tasksText = farmTasksN > 0
    ? farmTasksN + ' ' + ruPlural(farmTasksN, 'задача', 'задачи', 'задач') + ' сегодня'
    : 'задач нет'
  // Реальный аккаунт: строка строится из стада (rpc_get_farm_summary). Демо/аноним: цикл из сида.
  let farmSub: string
  if (farm.herd) {
    farmSub = farm.herd.totalHeads > 0
      ? 'Ферма · ' + farm.herd.totalHeads + ' ' + ruPlural(farm.herd.totalHeads, 'голова', 'головы', 'голов')
        + ' · ' + farm.herd.groupCount + ' ' + ruPlural(farm.herd.groupCount, 'группа', 'группы', 'групп')
        + ' · ' + tasksText
      : 'Ферма · стадо не заполнено'
  } else if (farm.cycle) {
    farmSub = 'Ферма · ' + farm.cycle.phase + ', день ' + farm.cycle.day + ' · ' + tasksText
  } else {
    farmSub = 'Ферма · ' + tasksText
  }
  if (farm.herd && farm.herd.totalHeads > 0 && farmOverdue) farmSub += ' · есть просрочка'
  else if (!farm.herd && farmOverdue) farmSub += ' · есть просрочка'

  return (
    <ShellFrame label={'Главная · ' + membership}>
      <HomeHead sticker={sticker} />
      {loading ? <SkeletonBlocks n={5} /> : (
        <div className="home-stack">
          <HomeBanner variant={bannerVariant} onAct={onBanner} />
          <ServiceGrid onOpen={openService} />

          {decisions.length > 0 && (
            <div className="blk">
              <TierHead tone="amber" label="ТРЕБУЕТ РЕШЕНИЯ" count={decisions.length}
                right={decisions.length > 3 ? <button className="tier-more" onClick={() => go({ name: 'messages' })}>ещё {decisions.length - 3} →</button> : null} />
              <div className="stack8">
                {decisions.slice(0, 3).map((d) => <DecisionCard key={d.id} d={d} />)}
              </div>
            </div>
          )}

          {observe.length > 0 && (
            <div className="blk">
              <TierHead tone="gray" label="ИДЁТ САМО" count={observe.length}
                right={observe.length > 3 ? <button className="tier-more" onClick={() => go({ name: 'p1list' })}>все партии →</button> : null} />
              <div className="stack8">
                {observe.slice(0, 3).map((o) => <ObserveCard key={o.id} o={o} />)}
              </div>
            </div>
          )}

          <div className="blk">
            <TierHead label="БЫСТРЫЙ ДОСТУП" />
            <div className="stack8">
              <button className="work-farm" onClick={() => go({ name: 'farm' })}>
                <span className="wf-ic"><ShIc k="farm" size={15} /></span>
                <span className="wf-t">{farmSub}</span>
                <span className="att-arr"><ShIc k="chev" size={13} /></span>
              </button>
              {showAhead && <AheadBlock items={farm.planFuture} />}
            </div>
          </div>
        </div>
      )}
    </ShellFrame>
  )
}

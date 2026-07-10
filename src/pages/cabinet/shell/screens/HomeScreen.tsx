// AgOS · Главная — структура прототипа (agos-farmer home.jsx): хедер ask-бар + аватар,
// баннер-карусель (картинки), грид сервисов ×4, ярусы «Требует решения» / «Идёт само» /
// «Быстрый доступ». Данные реальные (buildDecisions/buildObserve, rpc_get_farm_summary).

import { ruPlural } from '../data/fmt'
import { farmOpenTasks, type FarmState } from '../data/farm-seed'
import type { BannerCard, ServiceDef } from '../data/banners'
import type { DecisionCardModel, ObserveItemModel } from '../data/membership'
import type { StickerData } from '../data/prices'
import type { MembershipStatus, Route } from '../types'
import { IonShellFrame } from '../components/IonShellFrame'
import { HomeHead } from '../components/HomeHead'
import { HomeBanner } from '../components/HomeBanner'
import { ServiceGrid } from '../components/ServiceGrid'
import { HomeStartLadder } from '../components/HomeStartLadder'
import { TierHead } from '../components/TierHead'
import { DecisionCard } from '../components/DecisionCard'
import { ObserveCard } from '../components/ObserveCard'
import { SkeletonBlocks } from '../components/SkeletonBlocks'
import { PhIcon } from '../components/icons/PhIcon'

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
  onRefresh?: () => Promise<unknown>
}

export function HomeScreen({ membership, farm, decisions, observe, loading, go, onRefresh }: Props) {
  const farmTasksN = farmOpenTasks(farm).length
  const farmOverdue = (farm.tasks || []).some((t) => t.overdue && !t.done && !t.dismissed)
  const tasksText = farmTasksN > 0
    ? farmTasksN + ' ' + ruPlural(farmTasksN, 'задача', 'задачи', 'задач') + ' сегодня'
    : 'задач нет'
  // Реальный аккаунт: строка из стада (rpc_get_farm_summary). Демо/аноним: цикл из сида.
  let farmSub: string
  if (farm.herd) {
    farmSub = farm.herd.totalHeads > 0
      ? 'Ферма · ' + farm.herd.totalHeads + ' ' + ruPlural(farm.herd.totalHeads, 'голова', 'головы', 'голов')
        + ' · ' + tasksText
      : 'Ферма · стадо не заполнено'
  } else if (farm.cycle) {
    farmSub = 'Ферма · ' + farm.cycle.phase + ', день ' + farm.cycle.day + ' · ' + tasksText
  } else {
    farmSub = 'Ферма · ' + tasksText
  }
  if (farmOverdue) farmSub += ' · есть просрочка'

  // Стартовый модуль-лестница (ARS-209) ведёт фермера по первым шагам. Показываем на
  // стадиях онбординга (none/pending/approved — независимо от ярусов, иначе карточка
  // «Заявка на рассмотрении» прятала бы лестницу) ИЛИ когда ярусы пусты (член без стада/
  // сделок). Сам модуль растворяется, когда онбординг завершён (член + стадо). HS-5.
  const herdFilled = !!farm.herd && farm.herd.totalHeads > 0
  const quiet = decisions.length === 0 && observe.length === 0
  const onboarding = membership === 'none' || membership === 'pending' || membership === 'approved'

  return (
    <IonShellFrame label={'Главная · ' + membership} onRefresh={onRefresh}>
      <HomeHead />
      {loading ? <SkeletonBlocks n={5} /> : (
        <div className="home-stack">
          <HomeBanner />
          <ServiceGrid />
          <div className="home-div" />

          {(onboarding || quiet) && <HomeStartLadder herdFilled={herdFilled} />}

          {decisions.length > 0 && (
            <div className="blk">
              <TierHead label="Требует решения" />
              <div className="home-list">
                {decisions.map((d) => <DecisionCard key={d.id} d={d} />)}
              </div>
            </div>
          )}

          {observe.length > 0 && (
            <div className="blk">
              <TierHead
                label="Идёт само"
                right={<button className="tier-more" onClick={() => go({ name: 'market' })}>все партии<PhIcon name="chevronRight" size={12} /></button>}
              />
              <div className="home-list">
                {observe.map((o) => <ObserveCard key={o.id} o={o} />)}
              </div>
            </div>
          )}

          <div className="blk">
            <TierHead label="Быстрый доступ" />
            <div className="stack8">
              <button className="work-farm" onClick={() => go({ name: 'farm' })}>
                <span className="wf-ic"><PhIcon name="sprout" size={22} /></span>
                <span className="wf-t">{farmSub}</span>
                <span className="att-arr"><PhIcon name="chevronRight" size={16} /></span>
              </button>
            </div>
          </div>
        </div>
      )}
    </IonShellFrame>
  )
}

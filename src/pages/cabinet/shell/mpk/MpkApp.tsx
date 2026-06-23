// AgOS · TSP-3 · Корень оболочки МПК (мясокомбинат). Мок, без Supabase.
// Аналог CabinetApp, но проще: 2 маршрута (home/tsp), модалы и одна шторка.

import { useState, useEffect } from 'react'
import '../cabinet.css'
import { supabase } from '@/lib/supabase'
import { loadAccountProfile } from '@/lib/account'
import { Toast } from '../components/Toast'
import { MpkHomeScreen } from './screens/MpkHomeScreen'
import { MpkTspScreen } from './screens/MpkTspScreen'
import { CreatePoolModal } from './modals/CreatePoolModal'
import { PoolMonitorModal } from './modals/PoolMonitorModal'
import { BatchDetailModal } from './modals/BatchDetailModal'
import { DealClosedModal } from './modals/DealClosedModal'
import { ContactTuranSheet } from './sheets/ContactTuranSheet'
import { seedPools } from './data/pools'
import { loadMarketBatches, seedMarketBatches, type MarketBatch } from './data/market'
import { loadMyPools, loadPoolMatches, closeDuePools } from './data/pools-load'
import type {
  MpkMembership, MpkModal, MpkRoute, MpkSheet, MpkState, MpkTypeStatus, Pool,
} from './types'

interface MpkAppProps {
  // Начальное состояние можно переопределить для дев-режима
  initialState?: Partial<MpkState>
}

// Гейты МПК из БД. Тип МПК назначается при регистрации (organization_type_assignments)
// → наличие 'mpk' = подтверждён. Членство: registered → нужен self-join; observer/active_buyer = активно.
function deriveMpkType(orgTypes: string[]): MpkTypeStatus {
  return orgTypes.includes('mpk') ? 'approved' : 'under_review'
}
function deriveMpkMembership(level: string | null): MpkMembership {
  if (level === 'observer' || level === 'active_buyer') return 'active'
  if (level) return 'submitted'   // 'registered' — членство на рассмотрении (нужен self-join)
  return 'none'
}

export function MpkApp({ initialState }: MpkAppProps = {}) {
  const [typeStatus, setTypeStatus] = useState<MpkTypeStatus>(initialState?.typeStatus ?? 'under_review')
  const [membership, setMembership] = useState<MpkMembership>(initialState?.membership ?? 'submitted')
  const [pools, setPools] = useState<Pool[]>(initialState?.pools ?? seedPools())
  const [route, setRoute] = useState<MpkRoute>({ name: 'home' })
  const [modal, setModal] = useState<MpkModal>(null)
  const [sheet, setSheet] = useState<MpkSheet>(null)
  const [toast, setToast] = useState<{ id: number; text: string } | null>(null)

  // Профиль реального МПК-аккаунта перекрывает демо; иначе — демо-фолбэк.
  const [orgName, setOrgName] = useState(initialState?.orgName ?? 'ТОО «АгроМит»')
  const [region, setRegion] = useState(initialState?.region ?? 'ЮКО')
  const [bin, setBin] = useState(initialState?.bin ?? '123456789012')
  const [orgId, setOrgId] = useState<string | null>(null)  // org реального МПК — для self-serve RPC
  // Маркет-борд: реальные партии ферм через RPC; seed — демо-фолбэк (аноним/нет backend).
  const [marketBatches, setMarketBatches] = useState<MarketBatch[]>(seedMarketBatches())
  useEffect(() => {
    let alive = true
    loadAccountProfile('mpk').then((p) => {
      if (!alive || !p) return
      if (p.name) setOrgName(p.name)
      if (p.district) setRegion(p.district)
      if (p.bin) setBin(p.bin)
      if (p.orgId) {
        setOrgId(p.orgId)
        // Реальный аккаунт МПК — гейты типа/членства из БД (вместо демо-дефолтов).
        setTypeStatus(deriveMpkType(p.orgTypes))
        setMembership(deriveMpkMembership(p.membershipLevel))
      }
    })
    loadMarketBatches().then((list) => {
      if (alive && list !== null) setMarketBatches(list)
    })
    // Реальные пулы МПК из БД; null (аноним/нет backend) — оставляем seed-демо.
    // Перед загрузкой — авто-закрытие просроченных пулов (D-AUTOCLOSE-01).
    closeDuePools().then(() => loadMyPools()).then((list) => {
      if (alive && list !== null) setPools(list)
    })
    return () => { alive = false }
  }, [])

  // Лёгкий поллинг (D-SYNC-01): пулы и маркет-борд обновляются раз в 20с — МПК
  // видит авто-матч партий фермеров и изменения без перезагрузки. Безопасно для
  // демо/анонима: loadMyPools/loadMarketBatches вернут null → seed сохраняется.
  useEffect(() => {
    const id = setInterval(() => {
      closeDuePools().then(() => loadMyPools()).then((list) => { if (list !== null) setPools(list) })
      loadMarketBatches().then((list) => { if (list !== null) setMarketBatches(list) })
    }, 20000)
    return () => clearInterval(id)
  }, [])

  // Перечитать маркет-борд (после матча матченная партия уходит из published).
  const refetchMarket = () =>
    loadMarketBatches().then((list) => { if (list !== null) setMarketBatches(list) })

  // Перечитать пулы из БД (после смены статуса/матча).
  const refetchPools = () =>
    loadMyPools().then((list) => { if (list !== null) setPools(list) })

  // Реальный перевод статуса пула в БД. Бросает при ошибке (caller покажет тост).
  const advancePool = async (poolId: string, status: string) => {
    const { error } = await supabase.rpc('rpc_self_advance_pool_status', {
      p_pool_id: poolId, p_new_status: status,
    })
    if (error) throw new Error(error.message)
    await refetchPools()
  }

  // Реальный оффер МПК → партия фермера. Бросает при ошибке (caller покажет тост).
  const offerBatch = async (poolId: string, batchId: string, heads: number) => {
    const { error } = await supabase.rpc('rpc_self_match_batch_to_pool', {
      p_pool_id: poolId, p_batch_id: batchId, p_matched_heads: heads,
    })
    if (error) throw new Error(error.message)
    await refetchMarket()
  }

  // Реальное self-serve вступление в членство (registered → observer). Бросает при ошибке.
  const joinMembership = async () => {
    if (!orgId) return
    const { error } = await supabase.rpc('rpc_self_join_membership', { p_organization_id: orgId })
    if (error) throw new Error(error.message)
    const p = await loadAccountProfile('mpk')
    if (p) setMembership(deriveMpkMembership(p.membershipLevel))
  }

  const tspOpen = typeStatus === 'approved' && (membership === 'grace' || membership === 'active')

  const showToast = (text: string) => {
    const t = { id: Date.now(), text }
    setToast(t)
    setTimeout(() => setToast((cur) => (cur && cur.id === t.id ? null : cur)), 2800)
  }
  const patchPool = (id: string, patch: Partial<Pool>) =>
    setPools((ps) => ps.map((p) => (p.id === id ? { ...p, ...patch } : p)))
  const addPool = (p: Pool) => setPools((ps) => [p, ...ps])

  return (
    <div className="agos-cabinet-stage">
      {route.name === 'home' ? (
        <MpkHomeScreen
          typeStatus={typeStatus}
          membership={membership}
          pools={pools}
          tspOpen={tspOpen}
          orgName={orgName}
          region={region}
          bin={bin}
          onOpenTsp={() => setRoute({ name: 'tsp' })}
          onOpenPool={(id) => setModal({ kind: 'pool_monitor', poolId: id })}
          onOpenContactTuran={(topic) => setSheet({ kind: 'contact_turan', topic })}
          realAccount={orgId !== null}
          onSimulateApprove={() => { setTypeStatus('approved'); showToast('Тип МПК подтверждён (демо)') }}
          onSimulateMember={() => {
            if (orgId) {
              joinMembership()
                .then(() => showToast('Членство активировано'))
                .catch((e) => showToast('Не удалось: ' + (e instanceof Error ? e.message : '')))
            } else {
              setMembership('grace'); showToast('Членство активировано (демо)')
            }
          }}
        />
      ) : (
        <MpkTspScreen
          pools={pools}
          batches={marketBatches}
          onBack={() => setRoute({ name: 'home' })}
          onCreatePool={() => setModal({ kind: 'create_pool' })}
          onOpenPool={(id) => setModal({ kind: 'pool_monitor', poolId: id })}
          onOpenBatch={(id) => setModal({ kind: 'batch_detail', batchId: id })}
        />
      )}

      {/* Модалы */}
      {modal?.kind === 'create_pool' && (
        <CreatePoolModal
          orgId={orgId}
          onClose={() => setModal(null)}
          onSubmit={(pool) => { addPool(pool); setModal(null); showToast('Заявка на закупку создана') }}
        />
      )}
      {modal?.kind === 'pool_monitor' && (() => {
        const pool = pools.find((p) => p.id === modal.poolId)
        if (!pool) return null
        return (
          <PoolMonitorModal
            pool={pool}
            onClose={() => setModal(null)}
            onPatch={(patch) => patchPool(pool.id, patch)}
            toast={showToast}
            onContactTuran={() => { setModal(null); setSheet({ kind: 'contact_turan' }) }}
            onAdvance={advancePool}
            onLoadMatches={loadPoolMatches}
          />
        )
      })()}
      {modal?.kind === 'batch_detail' && (
        <BatchDetailModal
          batch={marketBatches.find((b) => b.id === modal.batchId)}
          pools={pools.filter((p) => p.status === 'filling')}
          onClose={() => setModal(null)}
          toast={showToast}
          onMatch={offerBatch}
          onOffer={(deal) => setModal({ kind: 'deal_closed', deal })}
        />
      )}
      {modal?.kind === 'deal_closed' && (
        <DealClosedModal
          deal={modal.deal}
          onClose={() => setModal(null)}
          toast={showToast}
        />
      )}

      {/* Шторки */}
      {sheet?.kind === 'contact_turan' && (
        <ContactTuranSheet
          open
          topic={sheet.topic}
          onClose={() => setSheet(null)}
          onSubmit={() => { setSheet(null); showToast('Обращение принято') }}
        />
      )}

      <Toast toast={toast} />
    </div>
  )
}

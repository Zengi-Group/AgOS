// AgOS · TSP-3 · Типы МПК (мясокомбинат). Мок-оболочка, аналог фермерской.

export type MpkTypeStatus = 'under_review' | 'approved' | 'rejected'
export type MpkMembership = 'none' | 'submitted' | 'grace' | 'active'

export type PoolStatus =
  | 'filling'    // набирается
  | 'filled'     // набран, ждёт подтверждения
  | 'executing'  // приёмка (контакты раскрыты)
  | 'expired'    // истёк
  | 'closed'     // закрыт admin'ом
  | 'executed'   // завершён

export type MpkCatKey = 'premium' | 'vysshaya' | 'pervaya' | 'vtoraya' | 'mrs_vyssh' | 'mrs_perv'

export interface MpkCatDef {
  name: string
  floorPrice: number   // жёсткий минимум — блокирует публикацию
}

export const MPK_CATS: Record<MpkCatKey, MpkCatDef> = {
  premium:    { name: 'КРС · Премиум',  floorPrice: 1850 },
  vysshaya:   { name: 'КРС · Высшая',   floorPrice: 1650 },
  pervaya:    { name: 'КРС · Первая',   floorPrice: 1500 },
  vtoraya:    { name: 'КРС · Вторая',   floorPrice: 1350 },
  mrs_vyssh:  { name: 'МРС · Высшая',   floorPrice: 950  },
  mrs_perv:   { name: 'МРС · Первая',   floorPrice: 850  },
}

export interface PoolLine {
  catKey: MpkCatKey
  price: number          // ₸/кг
  maxHeads?: number      // необязательно
  breed?: string         // желаемая порода строки (пусто = любая) — жёсткий матч
}

export interface SupplierRow {
  id: string
  rating: number         // 1–5
  heads: number
  price: number
  deliveryStatus: 'awaiting_dispatch' | 'in_transit' | 'delivered' | 'withdrawn'
  farmName?: string      // null до executing
  district?: string
  myRating?: number      // оценка МПК после executed
  // Слайс 9 (S4): поля для документа сделки + более полной карточки поставщика.
  batchId?: string
  cat?: string           // код категории партии (для лейбла)
  grade?: string | null  // сорт КРС (VS/S/NS)
  breed?: string
  avgWeight?: number     // средний вес, кг
  farmPhone?: string     // раскрыт после закрытия пула
  matchedAt?: string | null
  confirmedAt?: string | null
  dispatchedAt?: string | null
  deliveredAt?: string | null
}

export interface Pool {
  id: string
  status: PoolStatus
  title: string          // auto: «{catKey} · {region}»
  region: string
  totalHeads: number
  filledHeads: number
  targetMonth: string    // 'этот месяц' | 'следующий месяц' и т.д.
  lines: PoolLine[]
  suppliers?: SupplierRow[]   // раскрываются при executing
  createdAt: string
  executionResult?: 'full' | 'partial' | 'failed'
}

export interface MpkState {
  typeStatus: MpkTypeStatus
  membership: MpkMembership
  pools: Pool[]
  orgName: string
  region: string
  bin: string
}

export type MpkRoute =
  | { name: 'home' }
  | { name: 'tsp' }
  | { name: 'offers' }   // входящие broadcast-офферы (Слайс C)

// Входящий broadcast-оффер от фермера (rpc_get_incoming_offers). Личность фермера
// НЕ раскрыта (D-M6-12) — только характеристики партии + цена + дедлайн ответа.
export type OfferStatus = 'pending' | 'accepted' | 'rejected' | 'expired' | 'withdrawn'

export interface IncomingOffer {
  id: string             // offers.id
  batchId: string        // batches.id
  cat: string            // код категории партии (для лейбла)
  breed: string
  heads: number
  avgWeight: number      // кг
  region: string         // район фермы (без личности)
  windowLabel: string    // окно готовности
  offeredPrice: number   // ₸/кг (ask фермера = пол)
  expiresAt: Date        // дедлайн ответа МПК (FCFS)
  status: OfferStatus
}

// Сделка прямой покупки с маркет-борда (после согласия фермера).
// Имя фермы раскрывается только при подтверждении сделки (D40 — анонимность до сделки).
export interface PendingDeal {
  batchId: string
  catName: string
  farm: string         // раскрытое имя фермы
  region: string
  heads: number
  avgWeight: number    // кг
  price: number        // ₸/кг согласованная
}

export type MpkModal =
  | null
  | { kind: 'create_pool' }
  | { kind: 'pool_monitor'; poolId: string }
  | { kind: 'batch_detail'; batchId: string }
  | { kind: 'deal_closed'; deal: PendingDeal }

export type MpkSheet =
  | null
  | { kind: 'contact_turan'; topic?: string }

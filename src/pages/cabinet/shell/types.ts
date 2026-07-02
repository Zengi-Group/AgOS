// AgOS · Этап 1 · Типы оболочки фермера.
// Источник истины — прототип shell/* (data.jsx, app.jsx, ui.jsx, cabinet.jsx).

export type MembershipStatus =
  | 'none'
  | 'pending'
  | 'rejected'
  | 'approved'
  | 'active'
  | 'expiring'
  | 'grace'
  | 'expired'
  | 'terminated'

// Имена экранов (табы + вложенные)
export type RouteName =
  | 'home'
  | 'farm'
  | 'market'
  | 'shop'
  | 'messages'
  | 'cabinet'
  | 'services'
  | 'thread'
  | 'p1list'
  | 'batch'
  | 'review'
  | 'turan'

export interface Route {
  name: RouteName
  tid?: string
  back?: Route
  batchId?: string
  from?: string
}

export type SheetKind =
  | 'payvznos'
  | 'paypro'
  | 'progate'
  | 'membgate'
  | 'membdocs'
  | 'prices'
  | 'withdraw'     // WithdrawSheet
  | 'dispatch'     // DispatchSheet
  | 'batchprice'   // BatchPriceSheet
  | 'limit'        // LimitSheet

export interface SheetState {
  kind: SheetKind
  catKey?: string
  batchId?: string   // для withdraw, dispatch, batchprice
}

// Слайс 9: один проданный кусок партии (батч продаётся частями разным покупателям).
// Контакт покупателя раскрыт только после закрытия его пула (buyer/buyerPhone = null до).
export interface BatchAllocation {
  heads: number
  price: number
  // Слайс 9 S3: matched (ждёт заполнения пула) → confirmed (готов к отгрузке) →
  // dispatched (отгружен) → delivered (принят МПК). cancelled — кусок отменён.
  status: 'matched' | 'confirmed' | 'dispatched' | 'delivered' | 'cancelled'
  buyer?: string | null
  buyerPhone?: string | null
}

export interface Batch {
  id: string
  state: string
  cat?: string
  grade?: string | null   // сорт VS/S/NS из fn_tsp_batch_grade — для паритета с закупкой МПК
  breed?: string
  heads?: number
  avgWeight?: number
  age?: number
  fatness?: string
  district?: string
  price?: number
  dealPrice?: number | null
  matchedHeads?: number         // Слайс 9: сколько голов уже продано (сумма кусков)
  remainingHeads?: number       // Слайс 9: сколько осталось на рынке
  allocations?: BatchAllocation[]  // Слайс 9: проданные куски + покупатели
  history?: { t: string; d: string }[]
  [key: string]: unknown
}

export interface Notif {
  id: string
  ic: string
  title: string
  text: string
  time: string
  today: boolean
  unread: boolean
  batchId?: string
}

export interface AiMsg {
  who: 'c' | 'u'
  t: string
}

export interface ToastState {
  id: number
  text: string
}

export interface ShellState {
  membership: MembershipStatus
  isPro: boolean
  route: Route
  batches: Batch[]
  notifs: Notif[]
  aiLog: AiMsg[]
  newsOn: boolean
  profileIncomplete: boolean
  farmUnread: boolean
  turanUnread: boolean
  farm: import('./data/farm-seed').FarmState
}

export interface ShellContextValue {
  // навигация
  tab: RouteName
  go: (r: Route) => void
  route: Route
  // AI
  openAI: (ctx2?: string, opts?: { voice?: boolean; batchId?: string }) => void
  openPrices: (catKey: string) => void
  aiCtxDefault: string
  // бейджи
  marketDot: boolean
  msgBadge: number
  avatarDot: boolean
  avatarInitials: string   // инициалы хозяйства из реального аккаунта (демо-фолбэк «АД»)
  farmRegion: string | null // область регистрации хозяйства (regions.name_ru) — для read-only в визарде
  // состояние/действия
  offline: boolean
  offlineToast: () => void
  toast: (text: string) => void
  membership: MembershipStatus
  isPro: boolean
  memberAct: (act: string) => void
}

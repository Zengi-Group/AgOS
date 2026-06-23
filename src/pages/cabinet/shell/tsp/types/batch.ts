// AgOS · TSP-1 · Типы визарда «Новая партия» и публикации.
// Источник истины — p1/data.jsx (FRESH_WIZ) и p1/wizard.jsx.

export type CatKey = 'bychki' | 'telki' | 'korovy' | 'molodnyak'

export type BatchState =
  | 'draft' | 'scheduled' | 'published' | 'offering'
  | 'decision' | 'matched' | 'confirmed' | 'dispatched'
  | 'delivered' | 'cancelled'

export type PubVariant = 'A' | 'B' | 'C' | 'D'

// единый тип партии — из оболочки (одна точка истины)
export type { Batch } from '../../types'

// Черновик визарда — точно как FRESH_WIZ из прототипа
export interface WizState {
  step: 1 | 2 | 3 | 4 | 5
  breed: string
  heads: number
  avgWeight: number
  age: number
  fatness: string
  district: string
  windowPreset: string       // 'now' | 'm0' | 'm1' | 'm2' | 'own' | ''
  customFrom: string         // ISO date string
  customTo: string           // ISO date string
  catKey: CatKey | null
  catUnknown: boolean
  catLoading: boolean
  price: string              // строка для инпута, не число
  lowOk: boolean             // подтверждение цены ниже защитной
  draftId: string | null     // UUID черновика в Supabase (null = ещё не сохранён)
}

export const FRESH_WIZ: WizState = {
  step: 1, breed: '', heads: 20, avgWeight: 400, age: 18, fatness: '',
  district: 'Сайрамский район', // заполнить из профиля организации
  windowPreset: '', customFrom: '', customTo: '',
  catKey: null, catUnknown: false, catLoading: false,
  price: '', lowOk: false, draftId: null,
}

// AgOS · ARS-280 (Ферма 2.0 · F4) · Контракт верхних табов модуля «Ферма».
// Каркас — Slice8 §1: /cabinet/farm держит 4 таба (Обзор·Задачи·Стадо·Ещё, дефолт Обзор),
// паттерн `.mk-tabs` Рынка. Меж-табовые переходы (Slice8 §1.1, карта навигации handoff §3)
// выражаются одним вызовом goFarmTab(tab, params) — его дают экраны F5–F9 (Обзор-зоны,
// строки «Требует внимания» и т.п.). F4 предоставляет вызов и таб-бар; параметры несёт
// состояние таба и читают их тела при постройке (F5–F9). Аддитивно к нативному роутеру
// (внешний deep-link в под-таб — отдельный скоуп F10, ARS-286).

export type FarmTab = 'overview' | 'tasks' | 'herd' | 'more'

// Параметры перехода (Slice8 §1.1): Задачи открываются на горизонте/дне/задаче,
// Стадо — в режиме обхода или на карточке животного.
export interface FarmTabParams {
  horizon?: 'week' | 'month' | 'year'
  day?: string
  taskId?: string
  mode?: 'walk'
  animalId?: string
}

// Единый внутримодульный навигационный вызов (Slice8 §1.1).
export type GoFarmTab = (tab: FarmTab, params?: FarmTabParams) => void

// Порядок и подписи табов. Текстовые сегменты, без иконок и без счётчиков (Slice8 §0).
export const FARM_TABS: ReadonlyArray<{ key: FarmTab; label: string }> = [
  { key: 'overview', label: 'Обзор' },
  { key: 'tasks', label: 'Задачи' },
  { key: 'herd', label: 'Стадо' },
  { key: 'more', label: 'Ещё' },
]

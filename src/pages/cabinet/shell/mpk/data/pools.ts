// AgOS · TSP-3 · Сид-данные пулов и маркет-борда для мока МПК.

import type { Pool } from '../types'

export function seedPools(): Pool[] {
  return [
    {
      id: 'p1',
      status: 'filling',
      title: 'КРС · Алматинская обл.',
      region: 'Алматинская обл.',
      totalHeads: 200,
      filledHeads: 85,
      targetMonth: 'этот месяц',
      lines: [
        { catKey: 'vysshaya', price: 1700, maxHeads: 120 },
        { catKey: 'pervaya',  price: 1550, maxHeads: 80  },
      ],
      suppliers: [
        { id: 's1', rating: 4.8, heads: 40, price: 1700, deliveryStatus: 'awaiting_dispatch' },
        { id: 's2', rating: 4.2, heads: 25, price: 1700, deliveryStatus: 'awaiting_dispatch' },
        { id: 's3', rating: 4.5, heads: 20, price: 1550, deliveryStatus: 'awaiting_dispatch' },
      ],
      createdAt: '12 июн',
    },
    {
      id: 'p2',
      status: 'executing',
      title: 'КРС Премиум · ЮКО',
      region: 'ЮКО',
      totalHeads: 100,
      filledHeads: 100,
      targetMonth: 'этот месяц',
      lines: [
        { catKey: 'premium', price: 1900 },
      ],
      suppliers: [
        { id: 's4', rating: 4.9, heads: 60, price: 1900, deliveryStatus: 'in_transit',
          farmName: 'КХ Жаксылык', district: 'Сайрамский район' },
        { id: 's5', rating: 4.6, heads: 40, price: 1900, deliveryStatus: 'delivered',
          farmName: 'ТОО Агро-Бек', district: 'Толебийский район' },
      ],
      createdAt: '5 июн',
    },
  ]
}

// Сид-данные для маркет-борда (анонимные партии фермеров)
export interface MarketBatch {
  id: string
  catName: string
  region: string
  heads: number
  avgWeight: number
  minPrice: number
  breed: string
  vaccinated: boolean
  suitable: boolean
  suitableNote?: string
}

export function seedMarketBatches(): MarketBatch[] {
  return [
    { id: 'mb1', catName: 'Бычки откормочные', region: 'ЮКО', heads: 40, avgWeight: 450, minPrice: 1600, breed: 'Казахская белоголовая', vaccinated: true, suitable: true },
    { id: 'mb2', catName: 'Бычки откормочные', region: 'Алматинская обл.', heads: 30, avgWeight: 430, minPrice: 1650, breed: 'Ангус', vaccinated: true, suitable: true },
    { id: 'mb3', catName: 'Тёлки племенные', region: 'Жамбылская обл.', heads: 15, avgWeight: 370, minPrice: 1720, breed: 'Симментал', vaccinated: false, suitable: false, suitableNote: 'Нет вакцинации' },
    { id: 'mb4', catName: 'Молодняк до 12 мес', region: 'ЮКО', heads: 25, avgWeight: 260, minPrice: 1380, breed: 'Смешанная', vaccinated: true, suitable: false, suitableNote: 'Не соответствует минимальному весу' },
  ]
}

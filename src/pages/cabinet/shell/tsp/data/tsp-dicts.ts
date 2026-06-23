// AgOS · TSP-1 · Словари визарда — слово в слово из p1/data.jsx.

import type { CatKey } from '../types/batch'

export const CATS: Record<CatKey, { name: string; rec: number; prot: number }> = {
  bychki:    { name: 'Бычки откормочные',   rec: 1550, prot: 1400 },
  telki:     { name: 'Тёлки племенные',     rec: 1700, prot: 1550 },
  korovy:    { name: 'Коровы (выбраковка)', rec: 1100, prot: 950  },
  molodnyak: { name: 'Молодняк до 12 мес',  rec: 1350, prot: 1200 },
}

export const BREEDS = [
  'Казахская белоголовая', 'Ангус', 'Аулиеколь',
  'Симментал', 'Алатауская', 'Голштин', 'Смешанная/другая',
]

export const FATNESS = ['Хорошая', 'Средняя', 'Ниже средней']

// Районы — в реальном приложении из БД; фоллбэк, если профиль не заполнен.
export const DISTRICTS = [
  'Сайрамский район', 'Толебийский район', 'Казыгуртский район',
  'Тюлькубасский район', 'Ордабасынский район',
]

// NBSP — неразрывный пробел для цен (₸)
export const NBSP = ' '

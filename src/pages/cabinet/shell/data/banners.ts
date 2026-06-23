// AgOS · Этап 2 · Баннер «Актуальное», грид сервисов, новости TURAN.
// Перенесено из прототипа shell/data.jsx (слово в слово).

export interface BannerCard {
  k: string
  t: string
  s: string
  act: string
  ic?: string
  tone?: 'gold' | 'green'
  tenge?: boolean
  spark?: boolean
}

const BAN_CARD_COURSE: BannerCard = { k: 'КУРС TURAN · 15 МИН', t: 'Сезон отёла: 5 ошибок первых часов телёнка', s: 'Открыть курс', act: 'course', ic: 'vet', tone: 'green' }
const BAN_CARD_PRICES: BannerCard = { k: 'ЦЕНЫ TURAN', t: 'Защитные цены обновятся 15 июня', s: 'Открыть справочные цены', act: 'prices', tenge: true, tone: 'green' }
const BAN_CARD_JOIN: BannerCard = { k: 'ЧЛЕНСТВО TURAN', t: 'Вступите в TURAN — продажа партий, цены, защита сделок', s: 'Подать заявку →', act: 'join', tone: 'gold', spark: true }
const BAN_CARD_PRO: BannerCard = { k: 'PLATFORM PRO · 4 900 ₸/МЕС', t: 'Консультант TURAN — AI-зоотехник без ограничений', s: 'Подключить Pro →', act: 'pro', tone: 'gold', spark: true }

export const BANNER_SETS: Record<string, BannerCard[]> = {
  season: [BAN_CARD_COURSE, BAN_CARD_PRO, BAN_CARD_PRICES],
  campaign: [BAN_CARD_PRICES, BAN_CARD_PRO, BAN_CARD_COURSE],
  join: [BAN_CARD_JOIN, BAN_CARD_PRO, BAN_CARD_COURSE],
}

export interface ServiceDef { k: string; t: string; ic: string; green?: boolean; soon?: boolean; memberOnly?: boolean }
// Грид сервисов (зона 3 — ЯКОРЬ). «Маркет» в гриде НЕТ — у него отдельный таб.
export const SHELL_SERVICES: ServiceDef[] = [
  { k: 'market',  t: 'Рынок скота',   ic: 'market', green: true, memberOnly: true },
  { k: 'experts', t: 'Специалисты',   ic: 'vet' },
  { k: 'reg',     t: 'Рег. животных', ic: 'tag', soon: true },
  { k: 'all',     t: 'Все сервисы',   ic: 'grid' },
]

export const NEWS_ITEM = {
  k: 'НОВОСТИ TURAN',
  t: 'Семинар по откорму и племенному делу',
  sub: '28 июня · Шымкент · запись через офис ассоциации',
}

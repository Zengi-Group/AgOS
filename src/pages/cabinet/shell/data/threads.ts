// AgOS · ARS-231 · Сообщения: модель тредов «каждый модуль — собеседник» (паттерн Kaspi).
// Перенесено из прототипа app/messages.jsx (Фаза 03): треды = проекция событий модуля,
// «один объект — две поверхности» — decision Главной и pinned треда Рынка = один batch,
// одни хендлеры (DecH). Пустого треда нет — в спокойные периоды живёт дайджестом.

import { fmtMoney, NBSP, ruPlural } from './fmt'
import { catName } from './batches'
import { MEMBERSHIP_DICT, SEES_PRICES } from '../store'
import { CATS, PRICE_DELTA, HERD_FOR_CAT, SHORT_CAT } from './prices'
import type { FarmState } from './farm-seed'
import type { AiMsg, Batch, MembershipStatus, Notif } from '../types'
import type { PhIconName } from '../components/icons/PhIcon'
import type { CommMessage } from './messages-load'

// ═══ семантика тредов · цвет аватара фиксирован (§16 прототипа) ═══
// Консультант — звезда (accent, единственный оранжевый) · Рынок — янтарный ·
// Ферма — зелёный · TURAN — нейтральный «Т».
export type ThreadId = 'consultant' | 'market' | 'farm' | 'turan'

export interface ThreadMeta {
  n: string
  sub: string
  av: 'star' | 'market' | 'sprout' | 'Т'
  tone: 'accent' | 'amber' | 'green' | 'neutral'
}

export const MSG_META: Record<ThreadId, ThreadMeta> = {
  consultant: { n: 'Консультант', sub: 'AI · всегда на связи', av: 'star', tone: 'accent' },
  market: { n: 'Рынок', sub: 'события сделок', av: 'market', tone: 'amber' },
  farm: { n: 'Ферма', sub: 'сигналы и брифинги', av: 'sprout', tone: 'green' },
  turan: { n: 'TURAN', sub: 'членство · цены', av: 'Т', tone: 'neutral' },
}
export const MSG_ORDER: ThreadId[] = ['consultant', 'market', 'farm', 'turan']

// ═══ хендлеры тредов — те же действия, что у ярусов Главной (один объект — две поверхности) ═══
export interface ThreadH {
  lower: (b: Batch) => void
  open: (b: Batch) => void
  openId: (id: string) => void
  dispatch: (b: Batch) => void
  review: (b: Batch) => void
  farm: () => void
  member: (act: string) => void
  writeTuran: () => void
}

export interface ThreadMsgAction { t: string; kind: 'primary' | 'ghost'; fn: () => void; icon?: PhIconName }
export interface ThreadMsg {
  id: string
  t: string
  s?: string
  time?: string
  pin?: boolean
  actions?: ThreadMsgAction[]
  open?: () => void
  // ARS-225: сторона пузыря. По умолчанию 'incoming' (левый) — как у дайджестов.
  // Реальные сообщения фермера (его отправки) — 'outgoing' (правый).
  dir?: 'incoming' | 'outgoing'
}

export interface ThreadEnv {
  batches: Batch[]
  notifs: Notif[]
  membership: MembershipStatus
  farm: FarmState
  aiLog: AiMsg[]
  farmUnread: boolean
  turanUnread: boolean
  newsOn: boolean
  h: ThreadH
  // ARS-225: реальные сообщения канала поддержки (comm_messages), хронологически.
  // undefined = канал не загружен (аноним / RPC не задеплоен) → только дайджесты (мок).
  turanReal?: CommMessage[]
  // id текущего пользователя — чтобы отличить свои отправки (outgoing) от ответов TURAN.
  myUserId?: string | null
}

// Дисклеймер ст. 171 — слово в слово с PriceSheet (антитраст, показывается со справочными ценами).
export const PRICES_DISCLAIMER =
  'Справочная информация ассоциации TURAN. Не является обязательной — цену вы назначаете сами.'

const NEWS_ITEM = { t: 'Сезон отёла: 5 ошибок первых часов телёнка.', s: 'Курс TURAN · 15 минут' }

// ARS-225: короткое время сообщения. Сегодня → «ЧЧ:ММ», иначе → «5 июл».
function fmtMsgTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const now = new Date()
  const sameDay = d.toDateString() === now.toDateString()
  return sameDay
    ? new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(d)
    : new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' }).format(d)
}

// Подпись автора для входящих сообщений (ответы TURAN). Свои — без подписи.
const ACTOR_LABEL: Record<CommMessage['author_actor_type'], string> = {
  farmer: '', admin: 'TURAN', expert: 'Специалист TURAN', system: 'TURAN',
}

// Проекция реальных comm_messages в пузыри треда (ARS-225). Свои отправки — outgoing,
// ответы TURAN/специалиста — incoming с подписью автора.
function realTuranMsgs(real: CommMessage[], myUserId: string | null | undefined): ThreadMsg[] {
  return real.map((m) => {
    const mine = m.author_actor_type === 'farmer'
      && (!!myUserId ? m.author_user_id === myUserId : true)
    return {
      id: 'cm-' + m.id,
      t: m.body,
      s: mine ? undefined : (ACTOR_LABEL[m.author_actor_type] || undefined),
      time: fmtMsgTime(m.created_at),
      dir: mine ? 'outgoing' : 'incoming',
    } as ThreadMsg
  })
}

const activeTasksN = (farm: FarmState): number =>
  farm.tasks.filter((t) => !t.done && !t.dismissed && !t.postponed).length

// ═══ дайджест Рынка «без триггеров» — динамика из активных партий (§14 прототипа) ═══
const DIGEST_STATES = ['scheduled', 'published', 'offering', 'matched', 'confirmed', 'dispatched']
function marketDigest(batches: Batch[]): string {
  const act = batches.filter((b) => DIGEST_STATES.includes(b.state))
  if (act.length === 0) return 'Активных партий нет. Выставьте партию — покупателя найдёт TURAN.'
  const byCat: Record<string, number> = {}
  act.forEach((b) => { const k = b.cat ?? 'прочее'; byCat[k] = (byCat[k] ?? 0) + 1 })
  const parts = Object.keys(byCat).map((k) => {
    const name = (SHORT_CAT[k] ?? k).toLowerCase()
    const n = byCat[k] ?? 0
    return name + (n > 1 ? ` (${n})` : '')
  })
  return 'Партии в работе: ' + parts.join(', ') + ' — всё идёт по плану.'
}

// ═══ сообщения треда (проекция событий модуля) ═══
function marketThreadMsgs({ batches, notifs, h }: ThreadEnv): ThreadMsg[] {
  const msgs: ThreadMsg[] = []
  // pinned «ТРЕБУЕТ РЕШЕНИЯ» — те же тексты и хендлеры, что decision-карточка Главной
  batches.filter((b) => b.state === 'decision').forEach((b) => msgs.push({
    id: 'pin-dec-' + b.id, pin: true, time: 'сейчас',
    t: 'Покупатели не согласились по ' + fmtMoney(b.price as number) + NBSP + '₸/кг — '
      + catName(b) + ', ' + b.heads + ' голов. Ждёт вашего решения.',
    actions: [
      { t: 'Снизить цену', kind: 'primary', fn: () => h.lower(b), icon: 'tag' },
      { t: 'Варианты', kind: 'ghost', fn: () => h.open(b), icon: 'list' },
    ],
  }))
  batches.filter((b) => b.state === 'confirmed').forEach((b) => msgs.push({
    id: 'pin-shp-' + b.id, pin: true, time: 'сегодня',
    t: 'Сделка подтверждена — ' + catName(b) + ', ' + b.heads + ' голов. Покупатель ждёт отгрузку.',
    actions: [
      { t: 'Отгружена', kind: 'primary', fn: () => h.dispatch(b), icon: 'truck' },
      { t: 'Открыть', kind: 'ghost', fn: () => h.open(b), icon: 'chevronRight' },
    ],
  }))
  // отзыв — действие по желанию: обычное сообщение ленты, не закрепляется
  batches.filter((b) => b.state === 'delivered' && !b.review).forEach((b) => msgs.push({
    id: 'rev-' + b.id, time: 'сегодня',
    t: 'Партия принята покупателем — ' + catName(b) + '. Оцените сделку, когда удобно.',
    actions: [{ t: 'Оценить сделку', kind: 'ghost', fn: () => h.review(b), icon: 'starOutline' }],
  }))
  notifs.slice().reverse().forEach((n) => msgs.push({
    id: n.id, t: n.title, s: n.text, time: n.time,
    open: n.batchId ? () => h.openId(n.batchId as string) : undefined,
  }))
  // §14/15 прототипа: пустого треда нет — дайджест + проактив ассоциации.
  if (msgs.length === 0) {
    msgs.push({ id: 'mk-digest', time: 'сегодня', t: marketDigest(batches) })
    // проактив — строгий антитраст: только собственные публикации справочных цен TURAN
    const herd = HERD_FOR_CAT['bychki']
    if (PRICE_DELTA['bychki']?.trend === 'up' && herd) {
      msgs.push({
        id: 'mk-proactive', time: 'сегодня',
        t: 'Цена бычков растёт. У вас ' + herd.heads + ' голов на откорме готовы к продаже — рассмотреть?',
        s: 'По публикациям справочных цен TURAN.',
        actions: [{ t: 'Открыть стадо', kind: 'ghost', fn: h.farm, icon: 'cow' }],
      })
    }
  }
  return msgs
}

function farmThreadMsgs({ farm, h }: ThreadEnv): ThreadMsg[] {
  const n = activeTasksN(farm)
  const tasksLabel = n + ' ' + ruPlural(n, 'задача', 'задачи', 'задач') + ' на сегодня'
  const msgs: ThreadMsg[] = []
  if (farm.cycle) {
    msgs.push({
      id: 'f-brief', time: 'утром',
      t: 'Утренний брифинг: ' + farm.cycle.phase + ', день ' + farm.cycle.day + ' из '
        + farm.cycle.total + ' · ' + tasksLabel + '.',
      actions: [{ t: 'Открыть Ферму', kind: 'ghost', fn: h.farm, icon: 'sprout' }],
    })
  } else if (farm.herd && farm.herd.totalHeads > 0) {
    msgs.push({
      id: 'f-brief', time: 'утром',
      t: 'В стаде ' + farm.herd.totalHeads + ' голов в ' + farm.herd.groupCount + ' '
        + ruPlural(farm.herd.groupCount, 'группе', 'группах', 'группах') + ' · ' + tasksLabel + '.',
      actions: [{ t: 'Открыть Ферму', kind: 'ghost', fn: h.farm, icon: 'sprout' }],
    })
  } else {
    msgs.push({
      id: 'f-brief', time: 'сегодня',
      t: 'Заполните профиль фермы — здесь появятся утренние брифинги и сигналы по стаду.',
      actions: [{ t: 'Открыть Ферму', kind: 'ghost', fn: h.farm, icon: 'sprout' }],
    })
  }
  // сигнал: просроченная задача (реальный источник вместо демо-сигнала прототипа)
  const overdue = farm.tasks.find((t) => t.overdue && !t.done && !t.dismissed)
  if (overdue) {
    msgs.push({
      id: 'f-sig-' + overdue.id, time: 'утром',
      t: 'Задача просрочена: ' + overdue.title + '.',
      s: 'сигнал · план работ',
      actions: [{ t: 'Открыть Ферму', kind: 'ghost', fn: h.farm, icon: 'sprout' }],
    })
  }
  return msgs
}

function turanThreadMsgs({ membership, newsOn, h, turanReal, myUserId }: ThreadEnv): ThreadMsg[] {
  const msgs: ThreadMsg[] = []
  const entry = MEMBERSHIP_DICT[membership]
  const p = entry.plate
  if (p) {
    msgs.push({
      id: 't-memb', pin: !!p.cta, time: 'сегодня', t: p.t,
      actions: p.cta ? [{ t: p.cta, kind: 'primary', fn: () => h.member(p.act ?? 'apply'), icon: 'checkCircle' }] : [],
    })
  } else {
    msgs.push({ id: 't-memb', time: 'сегодня', t: entry.cab + '.' })
  }
  if (SEES_PRICES.includes(membership)) {
    const rows = ['bychki', 'telki'].map((k) => {
      const c = CATS[k]
      return c ? c.name + ' — ' + fmtMoney(c.rec) + NBSP + '₸/кг' : ''
    }).filter(Boolean)
    const prot = CATS['bychki']
    msgs.push({
      id: 't-prices', time: 'сегодня', t: 'Справочные цены обновлены.',
      s: rows.join(' · ') + (prot ? ' · защитная — ' + fmtMoney(prot.prot) + NBSP + '₸/кг' : '')
        + '. ' + PRICES_DISCLAIMER,
    })
  }
  if (newsOn) msgs.push({ id: 't-news', time: 'вчера', t: NEWS_ITEM.t, s: NEWS_ITEM.s })
  // ARS-225: реальная двусторонняя переписка канала поддержки ДОБАВЛЯЕТСЯ к дайджестам
  // (HS-2: дайджесты выше не удаляются). Порядок: контекст (членство/цены/новости) → диалог → CTA.
  if (turanReal && turanReal.length > 0) {
    msgs.push(...realTuranMsgs(turanReal, myUserId))
  }
  msgs.push({
    id: 't-write',
    t: 'Вопрос ассоциации? Напишите нам — ответим в течение 1 рабочего дня.',
    actions: [{ t: 'Написать в TURAN', kind: 'ghost', fn: h.writeTuran, icon: 'pencil' }],
  })
  return msgs
}

export function buildThreadMsgs(tid: ThreadId, env: ThreadEnv): ThreadMsg[] {
  if (tid === 'market') return marketThreadMsgs(env)
  if (tid === 'farm') return farmThreadMsgs(env)
  return turanThreadMsgs(env)
}

// ═══ модель списка тредов (превью = первое, что фермер увидит внутри) ═══
// cta — производное действие строки: primary-кнопка на реальном хендлере (env.h),
// показывается ТОЛЬКО когда у треда есть ожидающее решение фермера (решение Рынка,
// членство TURAN). «Один объект — две поверхности»: та же логика, что pinned в треде.
export interface ThreadListItem {
  tid: ThreadId
  time: string
  prev: string
  unread: number
  cta?: { t: string; fn: () => void }
}

export function buildThreadList(env: ThreadEnv): ThreadListItem[] {
  const { batches, notifs, membership, farm, aiLog, farmUnread, h } = env
  const dec = batches.filter((b) => b.state === 'decision')
  const lastAi = aiLog.length ? aiLog[aiLog.length - 1] : null
  const unreadN = notifs.filter((n) => n.unread).length
  const lastN = notifs[0]
  const p = MEMBERSHIP_DICT[membership].plate
  const firstDec = dec[0]
  const tasksN = activeTasksN(farm)
  return [
    {
      tid: 'consultant', unread: 0, time: lastAi ? 'сейчас' : '',
      prev: lastAi
        ? (lastAi.who === 'u' ? 'Вы: ' + lastAi.t : lastAi.t)
        : AI_FIRST,
    },
    {
      tid: 'market',
      unread: unreadN + dec.length,
      time: dec.length ? 'сейчас' : (lastN ? lastN.time : 'сегодня'),
      prev: firstDec
        ? 'Покупатели не согласились по ' + fmtMoney(firstDec.price as number) + NBSP + '₸/кг — нужно ваше решение'
        : (lastN ? lastN.title + ' — ' + lastN.text : marketDigest(batches)),
      cta: firstDec ? { t: 'Снизить цену', fn: () => h.lower(firstDec) } : undefined,
    },
    {
      tid: 'farm', unread: farmUnread ? 1 : 0, time: farm.cycle ? 'утром' : 'сегодня',
      prev: farm.cycle
        ? 'Утренний брифинг: ' + farm.cycle.phase + ', день ' + farm.cycle.day + ' · '
          + tasksN + ' ' + ruPlural(tasksN, 'задача', 'задачи', 'задач') + ' на сегодня'
        : 'Заполните профиль фермы — брифинги появятся здесь',
    },
    turanListItem(env, p, membership),
  ]
}

// ARS-225: строка списка для TURAN. Если есть реальные сообщения канала — превью и время
// берём из последнего сообщения (живой диалог важнее статичного дайджеста); иначе — как раньше
// (плашка членства / кабинетная подпись). CTA членства сохраняется (одно действие — две поверхности).
function turanListItem(
  env: ThreadEnv,
  p: (typeof MEMBERSHIP_DICT)[MembershipStatus]['plate'],
  membership: MembershipStatus
): ThreadListItem {
  const { turanReal, turanUnread, h } = env
  const last = turanReal && turanReal.length > 0 ? turanReal[turanReal.length - 1] : null
  const cta = p && p.cta ? { t: p.cta, fn: () => h.member(p.act ?? 'apply') } : undefined
  if (last) {
    const mine = last.author_actor_type === 'farmer'
    return {
      tid: 'turan',
      unread: turanUnread ? 1 : 0,
      time: fmtMsgTime(last.created_at) || 'сегодня',
      prev: (mine ? 'Вы: ' : '') + last.body,
      cta,
    }
  }
  return {
    tid: 'turan', unread: turanUnread ? 1 : 0, time: 'сегодня',
    prev: p ? p.t : MEMBERSHIP_DICT[membership].cab,
    cta,
  }
}

// ═══ AI · стартовая реплика и замоканные ответы (до подключения AI Gateway) ═══
// Антитраст: в ценовых ответах — только официальные справочные цены TURAN (P-AI-4/D61:
// никаких дозировок и агрегатов сделок; мок отвечает только справочными данными).
export const AI_FIRST = 'Чем помочь? Подскажу по ценам, кормам и здоровью стада.'

export function aiReply(text: string): string {
  const q = (text || '').toLowerCase()
  const b = CATS['bychki']
  // корм/здоровье проверяются РАНЬШЕ цены: «чем кормить бычков» — вопрос о корме,
  // хотя содержит «бычков» (ценовой триггер).
  if (/корм|рацион|откорм/.test(q) && !/цен|стоит|₸/.test(q))
    return 'По кормам ориентируюсь на вашу группу: укажите возраст, средний вес и текущий рацион — подскажу норму и срок откорма.'
  if (/цен|сколько|стоит|₸|бычк|тёлк|телк/.test(q) && b)
    return 'Рекомендуемая цена TURAN по категории «' + b.name + '» сегодня — '
      + fmtMoney(b.rec) + NBSP + '₸/кг, защитная — ' + fmtMoney(b.prot) + NBSP + '₸/кг. '
      + 'Это справочные значения ассоциации; решение по цене всегда за вами.'
  if (/корм|рацион|вес|откорм/.test(q))
    return 'По кормам ориентируюсь на вашу группу: укажите возраст, средний вес и текущий рацион — подскажу норму и срок откорма.'
  if (/болезн|здоров|лечен|телёнок|теленок|отёл|отел|хромает|кашля/.test(q))
    return 'Опишите симптомы и возраст животного. При тревожных признаках в сезон отёла лучше сразу открыть раздел «Ферма» — помогу по шагам.'
  return 'Принял. Уточните детали — отвечу по справочным данным TURAN: цены, корма, здоровье стада.'
}

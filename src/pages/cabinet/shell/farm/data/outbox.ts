// AgOS · ARS-286 (Ферма 2.0 · F10) · Outbox — FIFO-очередь надёжной доставки для мутаций
// «Обхода»/«Задач», написанных офлайн или при сбое RPC (Slice8 §7/§8, handoff §4.4). Ровно
// 6 RPC (7 call site — rpc_create_farm_task делят createInspectionTask и createFarmTask):
// rpc_mark_walkthrough · rpc_log_animal_event · rpc_close_animal_event · rpc_create_farm_task ×2 ·
// rpc_complete_farm_task · rpc_reschedule_farm_task. Идемпотентность — NK/CID/FSM по каждому RPC
// (см. call sites в farm-herd.ts/farm-overview.ts/farm-tasks.ts). «Тихого дропа НЕТ» — доменный
// отказ элемента остаётся в очереди как status:'failed' с видимым retry/remove (HerdScreen.tsx),
// не блокируя дренаж остальных элементов.
//
// Персистентность — appStorage (тот же KVStorage-адаптер, что offline-cache.ts), ключ
// СКОУПЛЕН по farmId (та же причина, что у cacheKey — общий браузер/аккаунт на несколько ферм).
// Подписка — subscribeOutbox зеркалит идиому useOnline() (platform/network.ts): внешний
// listener-набор + notify после каждой мутации очереди, потребляется через useSyncExternalStore.

import { supabase } from '@/lib/supabase'
import { appStorage } from '@/platform/storage'
import { isOnline, subscribeNetwork } from '@/platform/network'

const PREFIX = 'agos.cabinet.farm.outbox.v1.'

export interface OutboxItem {
  opId: string
  rpcName: string
  params: Record<string, unknown>
  queuedAt: string
  status: 'pending' | 'failed'
  failReason?: string
}

const keyFor = (farmId: string): string => PREFIX + farmId

function readQueue(farmId: string): OutboxItem[] {
  try {
    const raw = appStorage.getItem(keyFor(farmId))
    return raw ? (JSON.parse(raw) as OutboxItem[]) : []
  } catch {
    return []
  }
}

function writeQueue(farmId: string, items: OutboxItem[]): void {
  try {
    appStorage.setItem(keyFor(farmId), JSON.stringify(items))
  } catch {
    /* хранилище недоступно — очередь этой мутации не сохранится (тот же лимит, что у appStorage) */
  }
}

// readQueue()→mutate→writeQueue() сам по себе НЕ атомарен (обычный JSON-blob в localStorage,
// без CAS/версии) — callOrQueue/drainOutbox/retryItem/removeItem каждый делает этот цикл
// самостоятельно. Без сериализации конкурентные вызовы на одном farmId (eager drainOutbox на
// mount + повторный на 'online'-событие, пока пользователь тапает retry/remove по failed-элементу
// из того же окна) читают уже устаревший снапшот друг друга и затирают его через
// last-writer-wins — потерянный/воскресший элемент без единой ошибки в UI. Сериализуем через
// promise-chain мьютекс per-farm: каждый вызов ждёт завершения предыдущего на том же farmId.
const queueLocks = new Map<string, Promise<unknown>>()

function withQueueLock<T>(farmId: string, fn: () => Promise<T> | T): Promise<T> {
  const prev = queueLocks.get(farmId) ?? Promise.resolve()
  const run = prev.then(fn)
  queueLocks.set(farmId, run.then(() => undefined, () => undefined))
  return run
}

// {ok:false} в теле ответа — доменный отказ (RPC-33a), НЕ проблема связи. Различает
// drainOutbox/retryItem: доменный отказ → 'failed' (видимый, не блокирует остальные элементы);
// брошенная ошибка → остаётся 'pending' (сеть могла восстановиться на следующей попытке).
function isDomainRejection(data: unknown): boolean {
  return !!data && typeof data === 'object' && (data as Record<string, unknown>).ok === false
}

// ── подписки (мирроринг useOnline()/network.ts: внешний listener-набор + notify) ──
const listeners = new Map<string, Set<() => void>>()

// Версия per-farm, бампается при каждом notify() — getFailedItems() кэширует по ней (см. ниже):
// useSyncExternalStore требует стабильную (по ссылке) снапшот-функцию, а readQueue().filter(...)
// без кэша возвращал бы новый массив на каждый вызов даже без реальных изменений — React
// детектирует это как "getSnapshot should be cached" и роняет компонент (живой репро в WalkView).
const versions = new Map<string, number>()

function notify(farmId: string): void {
  versions.set(farmId, (versions.get(farmId) ?? 0) + 1)
  listeners.get(farmId)?.forEach((l) => l())
}

export function subscribeOutbox(farmId: string, listener: () => void): () => void {
  let set = listeners.get(farmId)
  if (!set) { set = new Set(); listeners.set(farmId, set) }
  set.add(listener)
  return () => {
    set!.delete(listener)
    if (set!.size === 0) listeners.delete(farmId)
  }
}

// Онлайн + успех/доменный-отказ → живой результат (см. шаг 3 контракта, ниже). Офлайн ИЛИ
// брошенная ошибка (сеть/5xx) → enqueue: {data:null, queued:true} — вызывающий синтезирует
// оптимистичный ответ (см. call sites в farm-herd.ts/farm-overview.ts/farm-tasks.ts).
export async function callOrQueue<T>(
  farmId: string,
  rpcName: string,
  params: Record<string, unknown>,
  idempotencyKeyField?: string,
): Promise<{ data: T | null; queued: boolean; opId: string }> {
  const opId = crypto.randomUUID()
  const finalParams: Record<string, unknown> = { ...params }
  if (idempotencyKeyField) finalParams[idempotencyKeyField] = opId

  if (isOnline()) {
    try {
      const { data, error } = await supabase.rpc(rpcName, finalParams)
      if (!error) {
        // Успех ИЛИ доменный отказ ({ok:false,reason}) — оба возвращаются как есть, вызывающий
        // уже умеет их различать («if (r.ok === false) {...} else {...}», не меняем этот путь).
        return { data: data as T, queued: false, opId }
      }
    } catch {
      /* сеть/5xx-класс — падаем в enqueue ниже */
    }
  }

  await withQueueLock(farmId, () => {
    const queue = readQueue(farmId)
    queue.push({ opId, rpcName, params: finalParams, queuedAt: new Date().toISOString(), status: 'pending' })
    writeQueue(farmId, queue)
  })
  notify(farmId)
  return { data: null, queued: true, opId }
}

// FIFO (queue — это appStorage-массив, элементы только append'ятся в конец, поэтому порядок
// индексов == порядок queuedAt). Доменный отказ одного элемента не блокирует остальные —
// «тихого дропа НЕТ», элемент остаётся видимым как 'failed'. Брошенная ошибка — стоп всей
// дальнейшей прогонки (следующий online-переход/маунт продолжит с этого места).
async function drainOutbox(farmId: string): Promise<void> {
  await withQueueLock(farmId, async () => {
    const queue = readQueue(farmId)
    let mutated = false

    for (let i = 0; i < queue.length; i++) {
      const item = queue[i]!
      if (item.status !== 'pending') continue

      try {
        const { data, error } = await supabase.rpc(item.rpcName, item.params)
        if (error) throw error
        if (isDomainRejection(data)) {
          item.status = 'failed'
          item.failReason = (data as Record<string, unknown>).reason as string | undefined
          mutated = true
          continue
        }
        queue.splice(i, 1)
        i--
        mutated = true
      } catch {
        break
      }
    }

    if (mutated) writeQueue(farmId, queue)
  })
  notify(farmId)
}

export function getPendingCount(farmId: string): number {
  return readQueue(farmId).filter((it) => it.status === 'pending').length
}

// Кэш по версии (см. notify() выше) — тот же снапшот-массив отдаётся, пока очередь этой фермы
// не менялась, иначе useSyncExternalStore считает каждый вызов новым состоянием и падает.
const failedItemsCache = new Map<string, { version: number; items: OutboxItem[] }>()

export function getFailedItems(farmId: string): OutboxItem[] {
  const version = versions.get(farmId) ?? 0
  const cached = failedItemsCache.get(farmId)
  if (cached && cached.version === version) return cached.items
  const items = readQueue(farmId).filter((it) => it.status === 'failed')
  failedItemsCache.set(farmId, { version, items })
  return items
}

// Живая связь §7 «строка появляется без ожидания сети (optimistic из outbox)» — экран не может
// оптимистично отрисовать факт, который знает только по локальному onDone-состоянию (это state
// компонента, теряется при ремаунте, и рискует задвоиться с реальной строкой после реплея).
// Вместо этого экран читает ещё-не-синканные операции ПРЯМО из очереди — тот же snapshot, что
// у pendingCount/getFailedItems, поэтому строка гаснет сама через notify(), когда drainOutbox
// уводит элемент из очереди (успех), без ручной сверки/дедупа на стороне компонента.
const pendingItemsCache = new Map<string, { version: number; items: OutboxItem[] }>()

export function getPendingItems(farmId: string): OutboxItem[] {
  const version = versions.get(farmId) ?? 0
  const cached = pendingItemsCache.get(farmId)
  if (cached && cached.version === version) return cached.items
  const items = readQueue(farmId).filter((it) => it.status === 'pending')
  pendingItemsCache.set(farmId, { version, items })
  return items
}

// Повтор одного элемента — те же переходы, что drainOutbox (успех → удалён; доменный отказ →
// 'failed'+reason; брошенная ошибка → назад в 'pending', пользователь может повторить ещё раз).
export async function retryItem(farmId: string, opId: string): Promise<void> {
  await withQueueLock(farmId, async () => {
    const queue = readQueue(farmId)
    const idx = queue.findIndex((it) => it.opId === opId)
    if (idx === -1) return
    const item = queue[idx]!

    try {
      const { data, error } = await supabase.rpc(item.rpcName, item.params)
      if (error) throw error
      if (isDomainRejection(data)) {
        item.status = 'failed'
        item.failReason = (data as Record<string, unknown>).reason as string | undefined
      } else {
        queue.splice(idx, 1)
      }
    } catch {
      item.status = 'pending'
      item.failReason = undefined
    }

    writeQueue(farmId, queue)
  })
  notify(farmId)
}

// Пользователь отказался от повтора — убрать элемент из очереди без попытки RPC.
export async function removeItem(farmId: string, opId: string): Promise<void> {
  await withQueueLock(farmId, () => {
    writeQueue(farmId, readQueue(farmId).filter((it) => it.opId !== opId))
  })
  notify(farmId)
}

// Автодренаж (Slice8 §7/handoff §4.4): при возврате сети + один раз на монтировании модуля
// Фермы. Вызывается ОДИН раз из FarmScreen.tsx (единственная точка монтирования модуля,
// F4/ARS-280) — не из отдельных экранов (Обзор/Задачи/Стадо монтируются/размонтируются при
// переключении табов; дублирование там дало бы конкурентные дренажи одной и той же очереди).
export function wireOutboxAutoDrain(farmId: string): () => void {
  void drainOutbox(farmId) // eager — очередь может быть непустой с прошлой офлайн-сессии
  return subscribeNetwork(() => {
    if (isOnline()) void drainOutbox(farmId)
  })
}

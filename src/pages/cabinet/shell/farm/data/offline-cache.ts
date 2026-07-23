// AgOS · ARS-286 (Ферма 2.0 · F10) · Read-cache поверх KVStorage (appStorage) — 4 агрегата
// экранов Фермы (Обзор · Задачи-Неделя/Месяц/Год · Стадо · Карточка животного, D145 §6)
// переживают точечный сбой сети/RPC: последний успешный ответ кэшируется в appStorage и
// отдаётся вместо ошибки — «данные на HH:MM» вместо «не удалось загрузить». Полностью
// generic — без привязки к конкретному RPC; caller передаёт cacheKey (СКОУПЛЕН по farmId —
// иначе кэш одной фермы протекал бы на другую в общем браузере/аккаунте) и fetcher-closure.
// Полный outbox для записи — outbox.ts (тот же F10, соседний модуль).

import { appStorage } from '@/platform/storage'

const PREFIX = 'agos.cabinet.farm.cache.v1.'

export interface CachedResult<T> {
  data: T
  fetchedAt: string
  source: 'live' | 'cache'
}

interface CacheEntry<T> {
  data: T
  fetchedAt: string
}

// fetcher() успешен → пишем {data, fetchedAt} в appStorage, отдаём source:'live'.
// fetcher() бросает → читаем тот же ключ; есть кэш → source:'cache' (последнее известное);
// нет кэша → перебрасываем исходную ошибку без изменений (существующее поведение
// «не удалось загрузить» для случая, когда показать вообще нечего).
export async function cachedFetch<T>(cacheKey: string, fetcher: () => Promise<T>): Promise<CachedResult<T>> {
  const key = PREFIX + cacheKey
  try {
    const data = await fetcher()
    const fetchedAt = new Date().toISOString()
    try {
      appStorage.setItem(key, JSON.stringify({ data, fetchedAt } satisfies CacheEntry<T>))
    } catch {
      /* хранилище недоступно (quota/private mode) — кэш необязателен, live-результат уже есть */
    }
    return { data, fetchedAt, source: 'live' }
  } catch (err) {
    const raw = appStorage.getItem(key)
    if (raw) {
      try {
        const entry = JSON.parse(raw) as CacheEntry<T>
        return { data: entry.data, fetchedAt: entry.fetchedAt, source: 'cache' }
      } catch {
        /* повреждённый кэш — падаем в rethrow ниже, как при полном отсутствии кэша */
      }
    }
    throw err
  }
}

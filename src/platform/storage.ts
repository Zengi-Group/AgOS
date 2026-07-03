// AgOS · S3 Platform-adapter (EngSpec §4, ARS-149): единый KV-слой поверх Web Storage.
// Ядро зовёт адаптер, адаптер — бэкенд. Web = localStorage/sessionStorage (поведение 1:1);
// CapacitorHost (S4) подменяет бэкенды на @capacitor/preferences через set*StorageBackend
// (secure, переживает чистку WebView-хранилища ОС).

export interface KVStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
}

// Async-контракт под supabase-js `auth.storage` (v2 принимает Promise-совместимый storage).
export interface AsyncKVStorage {
  getItem(key: string): Promise<string | null>
  setItem(key: string, value: string): Promise<void>
  removeItem(key: string): Promise<void>
}

// Обёртка над Web Storage: не роняет вызывающего (Safari private mode, quota) —
// прежние call-sites глотали эти ошибки сами, контракт сохраняем внутри адаптера.
// Store берём через thunk: обращение к window откладывается до первого вызова
// (модуль импортируется и в средах без DOM — unit-тесты, SSR-инструменты).
export function createWebKV(getStore: () => Storage): KVStorage {
  return {
    getItem(key) {
      try { return getStore().getItem(key) } catch { return null }
    },
    setItem(key, value) {
      try { getStore().setItem(key, value) } catch { /* quota / private mode */ }
    },
    removeItem(key) {
      try { getStore().removeItem(key) } catch { /* noop */ }
    },
  }
}

let appBackend: KVStorage = createWebKV(() => window.localStorage)
let draftBackend: KVStorage = createWebKV(() => window.sessionStorage)

// Persistent-скоуп: `agos.cabinet.v1`, кеш партий, платёжные флаги, сессия supabase-js.
export const appStorage: KVStorage = {
  getItem: (key) => appBackend.getItem(key),
  setItem: (key, value) => appBackend.setItem(key, value),
  removeItem: (key) => appBackend.removeItem(key),
}

// Session-скоуп: черновик визарда (form preservation, Dok6). Web = sessionStorage;
// нативка (S4) переводит на Preferences — черновик переживает рестарт приложения.
export const draftStorage: KVStorage = {
  getItem: (key) => draftBackend.getItem(key),
  setItem: (key, value) => draftBackend.setItem(key, value),
  removeItem: (key) => draftBackend.removeItem(key),
}

export function setAppStorageBackend(backend: KVStorage): void {
  appBackend = backend
}

export function setDraftStorageBackend(backend: KVStorage): void {
  draftBackend = backend
}

// supabase-js `auth.storage`: тот же appBackend, но async-контракт supabase.
// Web-путь идентичен дефолту supabase-js (localStorage, тот же sb-*-auth-token ключ).
export const authStorage: AsyncKVStorage = {
  async getItem(key) { return appBackend.getItem(key) },
  async setItem(key, value) { appBackend.setItem(key, value) },
  async removeItem(key) { appBackend.removeItem(key) },
}

// AgOS · S3 Platform-adapter (EngSpec §4, ARS-149): реальный сетевой статус для ctx.offline.
// Контракт Dok6 Slice1: navigator.onLine + события online/offline → баннер до восстановления
// сети. Web/webview = этот бэкенд; CapacitorHost (S4) подменяет на @capacitor/network.

import { useSyncExternalStore } from 'react'

export interface NetworkBackend {
  isOnline(): boolean
  subscribe(listener: () => void): () => void
}

// Структурный минимум от window: настоящий Window подходит, фейк в тестах — тоже.
type NetworkWindow = {
  navigator: { onLine: boolean }
  addEventListener(type: 'online' | 'offline', listener: () => void): void
  removeEventListener(type: 'online' | 'offline', listener: () => void): void
}

export function createNavigatorNetwork(win: NetworkWindow): NetworkBackend {
  return {
    isOnline: () => win.navigator.onLine,
    subscribe(listener) {
      win.addEventListener('online', listener)
      win.addEventListener('offline', listener)
      return () => {
        win.removeEventListener('online', listener)
        win.removeEventListener('offline', listener)
      }
    },
  }
}

// Ленивая инициализация: window трогаем при первом вызове, не при импорте
// (модуль импортируется и в средах без DOM — unit-тесты).
let backend: NetworkBackend | null = null
const getBackend = (): NetworkBackend => (backend ??= createNavigatorNetwork(window))

export function setNetworkBackend(next: NetworkBackend): void {
  backend = next
}

export const isOnline = (): boolean => getBackend().isOnline()
export const subscribeNetwork = (listener: () => void): (() => void) =>
  getBackend().subscribe(listener)

// true = сеть есть. useSyncExternalStore — статус консистентен при конкурентном рендере.
export function useOnline(): boolean {
  return useSyncExternalStore(subscribeNetwork, isOnline)
}

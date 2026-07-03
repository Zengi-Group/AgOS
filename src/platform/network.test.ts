// AgOS · S3 (ARS-149): unit-тесты сетевого адаптера. Среда node — window не трогаем:
// бэкенд конструируем из фейкового окна, seam — через setNetworkBackend.

import { describe, it, expect, beforeEach } from 'vitest'
import {
  createNavigatorNetwork,
  setNetworkBackend,
  isOnline,
  subscribeNetwork,
  type NetworkBackend,
} from './network'

function fakeWindow(initialOnline = true) {
  const listeners = new Map<string, Set<() => void>>()
  const win = {
    navigator: { onLine: initialOnline },
    addEventListener(type: string, cb: () => void) {
      if (!listeners.has(type)) listeners.set(type, new Set())
      listeners.get(type)!.add(cb)
    },
    removeEventListener(type: string, cb: () => void) {
      listeners.get(type)?.delete(cb)
    },
    fire(type: 'online' | 'offline') {
      win.navigator.onLine = type === 'online'
      listeners.get(type)?.forEach((cb) => cb())
    },
    count(type: string) {
      return listeners.get(type)?.size ?? 0
    },
  }
  return win
}

describe('createNavigatorNetwork (web/webview-бэкенд, Dok6 Slice1)', () => {
  it('isOnline отражает navigator.onLine', () => {
    const win = fakeWindow(true)
    const net = createNavigatorNetwork(win)
    expect(net.isOnline()).toBe(true)
    win.fire('offline')
    expect(net.isOnline()).toBe(false)
    win.fire('online')
    expect(net.isOnline()).toBe(true)
  })

  it('subscribe получает уведомления и отписывается без утечек', () => {
    const win = fakeWindow(true)
    const net = createNavigatorNetwork(win)
    let calls = 0
    const unsub = net.subscribe(() => { calls++ })
    expect(win.count('online')).toBe(1)
    expect(win.count('offline')).toBe(1)
    win.fire('offline')
    expect(calls).toBe(1)
    win.fire('online')
    expect(calls).toBe(2)
    unsub()
    expect(win.count('online')).toBe(0)
    expect(win.count('offline')).toBe(0)
    win.fire('offline')
    expect(calls).toBe(2)
  })
})

describe('setNetworkBackend — seam для CapacitorHost (S4)', () => {
  let online: boolean
  let notify: (() => void) | null

  beforeEach(() => {
    online = true
    notify = null
    const backend: NetworkBackend = {
      isOnline: () => online,
      subscribe(listener) {
        notify = listener
        return () => { notify = null }
      },
    }
    setNetworkBackend(backend)
  })

  it('isOnline / subscribeNetwork делегируют в установленный бэкенд', () => {
    expect(isOnline()).toBe(true)
    let seen: boolean | null = null
    const unsub = subscribeNetwork(() => { seen = isOnline() })
    online = false
    notify?.()
    expect(seen).toBe(false)
    unsub()
    expect(notify).toBeNull()
  })
})

// AgOS · S3 (ARS-149): unit-тесты KV-адаптера. Среда node — без DOM;
// web-бэкенд тестируем через фейковый Storage, seam — через set*StorageBackend.

import { describe, it, expect, beforeEach } from 'vitest'
import {
  createWebKV,
  appStorage,
  draftStorage,
  authStorage,
  setAppStorageBackend,
  setDraftStorageBackend,
  type KVStorage,
} from './storage'

function fakeStorage(): Storage {
  const map = new Map<string, string>()
  return {
    get length() { return map.size },
    clear: () => map.clear(),
    getItem: (k: string) => (map.has(k) ? map.get(k)! : null),
    setItem: (k: string, v: string) => { map.set(k, String(v)) },
    removeItem: (k: string) => { map.delete(k) },
    key: (i: number) => [...map.keys()][i] ?? null,
  }
}

function memoryKV(): KVStorage & { map: Map<string, string> } {
  const map = new Map<string, string>()
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k)! : null),
    setItem: (k, v) => { map.set(k, v) },
    removeItem: (k) => { map.delete(k) },
  }
}

describe('createWebKV', () => {
  it('читает/пишет/удаляет через переданный Storage', () => {
    const store = fakeStorage()
    const kv = createWebKV(() => store)
    expect(kv.getItem('x')).toBeNull()
    kv.setItem('x', '1')
    expect(kv.getItem('x')).toBe('1')
    kv.removeItem('x')
    expect(kv.getItem('x')).toBeNull()
  })

  it('не роняет вызывающего, если Storage бросает (private mode / quota)', () => {
    const throwing = () => {
      throw new Error('SecurityError')
    }
    const kv = createWebKV(throwing as unknown as () => Storage)
    expect(kv.getItem('x')).toBeNull()
    expect(() => kv.setItem('x', '1')).not.toThrow()
    expect(() => kv.removeItem('x')).not.toThrow()
  })
})

describe('appStorage / draftStorage — подмена бэкенда (seam для CapacitorHost, S4)', () => {
  let app: ReturnType<typeof memoryKV>
  let draft: ReturnType<typeof memoryKV>

  beforeEach(() => {
    app = memoryKV()
    draft = memoryKV()
    setAppStorageBackend(app)
    setDraftStorageBackend(draft)
  })

  it('appStorage делегирует в установленный бэкенд', () => {
    appStorage.setItem('agos.cabinet.v1', '{"route":{"name":"home"}}')
    expect(app.map.get('agos.cabinet.v1')).toBe('{"route":{"name":"home"}}')
    expect(appStorage.getItem('agos.cabinet.v1')).toBe('{"route":{"name":"home"}}')
    appStorage.removeItem('agos.cabinet.v1')
    expect(appStorage.getItem('agos.cabinet.v1')).toBeNull()
  })

  it('draftStorage изолирован от appStorage (session-скоуп ≠ persistent)', () => {
    draftStorage.setItem('agos.tsp.draft.v1', 'draft')
    expect(appStorage.getItem('agos.tsp.draft.v1')).toBeNull()
    expect(draftStorage.getItem('agos.tsp.draft.v1')).toBe('draft')
  })

  it('authStorage (supabase auth.storage) — async-обёртка того же app-бэкенда', async () => {
    await authStorage.setItem('sb-ref-auth-token', 'jwt')
    expect(app.map.get('sb-ref-auth-token')).toBe('jwt')
    await expect(authStorage.getItem('sb-ref-auth-token')).resolves.toBe('jwt')
    await authStorage.removeItem('sb-ref-auth-token')
    await expect(authStorage.getItem('sb-ref-auth-token')).resolves.toBeNull()
  })
})

import React, { createContext, useContext, useEffect, useState } from 'react'
import type { AgOSHost } from './AgOSHost'
import { detectHostKind } from './detect'
import { createWebHost } from './WebHost'

// Синхронный старт: web получает WebHost сразу (поведение S1 не меняется, без async
// на web-пути). Не-web хост резолвится асинхронно (см. resolveNativeHost) — модуль
// реализации подгружается динамически, чтобы Capacitor-граф не попал в web-бандл.
function initialHost(): AgOSHost | null {
  return detectHostKind() === 'web' ? createWebHost() : null
}

// CapacitorHost (S4) грузится динамически ТОЛЬКО на нативке → отдельный чанк, web его
// не тянет (3G-бюджет Dok6). WebViewHost (S7 / ARS-133) подключится сюда же.
async function resolveNativeHost(): Promise<AgOSHost> {
  const kind = detectHostKind()
  if (kind === 'capacitor') {
    const { createCapacitorHost } = await import('./CapacitorHost')
    return createCapacitorHost()
  }
  // webview (S7) пока не реализован — осознанный fallback на WebHost.
  console.warn(`AgOSHost: реализация '${kind}' ещё не подключена — fallback на WebHost`)
  return createWebHost()
}

const HostContext = createContext<AgOSHost | null>(null)

export function HostProvider({ children }: { children: React.ReactNode }) {
  const [host, setHost] = useState<AgOSHost | null>(initialHost)

  useEffect(() => {
    if (host) return
    // Нативный/webview хост: резолвим асинхронно. Нативный сплэш закрывает этот кадр
    // (SplashScreen прячется внутри createCapacitorHost после инициализации).
    let alive = true
    void resolveNativeHost().then((h) => {
      if (alive) setHost(h)
    })
    return () => {
      alive = false
    }
  }, [host])

  useEffect(() => {
    // PWA: service worker регистрируется через Host Bridge и ТОЛЬКО на web (EngSpec §5).
    if (host?.kind === 'web' && import.meta.env.PROD && 'serviceWorker' in navigator) {
      navigator.serviceWorker
        .register('/sw.js')
        .catch(err => console.warn('SW registration failed:', err))
    }
  }, [host])

  // До резолва нативного хоста ядро (AuthProvider и т.д.) не монтируется — гарантирует,
  // что storage/network-бэкенды установлены ДО первого чтения сессии supabase-js.
  if (!host) return null

  return <HostContext.Provider value={host}>{children}</HostContext.Provider>
}

export function useHost(): AgOSHost {
  const host = useContext(HostContext)
  if (!host) {
    throw new Error('useHost must be used within HostProvider')
  }
  return host
}

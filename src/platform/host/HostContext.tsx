import React, { createContext, useContext, useEffect, useState } from 'react'
import type { AgOSHost } from './AgOSHost'
import { detectHostKind } from './detect'
import { createWebHost } from './WebHost'

// Фабрика: CapacitorHost (S4) и WebViewHost (S7 / ARS-133) подключатся сюда же.
// До их появления любой не-web хост осознанно падает на WebHost.
function createHost(): AgOSHost {
  const kind = detectHostKind()
  if (kind !== 'web') {
    console.warn(`AgOSHost: реализация '${kind}' ещё не подключена — fallback на WebHost`)
  }
  return createWebHost()
}

const HostContext = createContext<AgOSHost | null>(null)

export function HostProvider({ children }: { children: React.ReactNode }) {
  const [host] = useState(createHost)

  useEffect(() => {
    // PWA: service worker регистрируется через Host Bridge и ТОЛЬКО на web (EngSpec §5).
    if (host.kind === 'web' && import.meta.env.PROD && 'serviceWorker' in navigator) {
      navigator.serviceWorker
        .register('/sw.js')
        .catch(err => console.warn('SW registration failed:', err))
    }
  }, [host])

  return <HostContext.Provider value={host}>{children}</HostContext.Provider>
}

export function useHost(): AgOSHost {
  const host = useContext(HostContext)
  if (!host) {
    throw new Error('useHost must be used within HostProvider')
  }
  return host
}

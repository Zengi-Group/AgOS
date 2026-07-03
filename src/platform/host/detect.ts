import type { HostKind } from './AgOSHost'

// Рантайм-детект хоста (EngSpec §2.2). Один Vite-билд — три поверхности.
export function detectHostKind(): HostKind {
  const w = window as unknown as {
    Capacitor?: { isNativePlatform?: () => boolean }
    AgOSNativeBridge?: unknown
    ReactNativeWebView?: unknown
  }
  if (w.Capacitor?.isNativePlatform?.()) return 'capacitor'
  if (w.AgOSNativeBridge || w.ReactNativeWebView) return 'webview'
  return 'web'
}

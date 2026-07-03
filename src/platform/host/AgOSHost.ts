// Host Bridge — единый анти-дивергентный контракт (EngSpec §2, ARS-147).
// Ядро AgOS (AuthContext, shell, push, upload) зовёт ТОЛЬКО этот интерфейс —
// никогда @capacitor/* или window.parent.postMessage напрямую.
// Реализации: WebHost (S1) · CapacitorHost (S4) · WebViewHost (S7 / ARS-133).

export type HostKind = 'web' | 'webview' | 'capacitor'

export interface HostCaps {
  haptics: boolean
  camera: boolean
  secureStorage: boolean
  statusBar: boolean
}

export interface AgOSHost {
  kind: HostKind
  // Сессия: web читает из supabase-js persistSession; webview принимает инъекцию хоста (ARS-134);
  // capacitor восстанавливает из secure Preferences.
  bootstrapSession(): Promise<{ access_token: string; refresh_token: string } | null>
  signOut(): Promise<void>
  // Push: возвращает нативный device-token (или null для web без web-push).
  registerPushToken(): Promise<string | null>
  onPushToken(handler: (token: string) => void): void
  // Deep-link: и cold-start, и в рантайме. Отдаёт path вида '/cabinet/batch/:id'.
  onDeepLink(handler: (path: string) => void): void
  // Capability-gated (могут быть no-op):
  readonly caps: HostCaps
  haptics(style: 'light' | 'medium' | 'heavy'): void
  pickImage(opts?: { source?: 'camera' | 'library' }): Promise<Blob | null>
}

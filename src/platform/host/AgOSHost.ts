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

// Device push token descriptor (S5 / ARS-153). provider+platform живут на стороне хоста —
// ядро НЕ импортирует @capacitor/* (ревью-инвариант §10), поэтому хост отдаёт их вместе
// с токеном. Соответствуют CHECK-ограничениям push_token (ARS-139) / rpc_register_push_token.
export interface PushToken {
  token: string
  provider: 'fcm' | 'apns'
  platform: 'android' | 'ios' | 'web'
}

export interface AgOSHost {
  kind: HostKind
  // Сессия: web читает из supabase-js persistSession; webview принимает инъекцию хоста (ARS-134);
  // capacitor восстанавливает из secure Preferences.
  bootstrapSession(): Promise<{ access_token: string; refresh_token: string } | null>
  signOut(): Promise<void>
  // Push: возвращает нативный device-token с provider/platform (или null для web без web-push).
  registerPushToken(): Promise<PushToken | null>
  onPushToken(handler: (token: PushToken) => void): void
  // Deep-link: и cold-start, и в рантайме. Отдаёт path вида '/cabinet/batch/:id'.
  onDeepLink(handler: (path: string) => void): void
  // Capability-gated (могут быть no-op):
  readonly caps: HostCaps
  haptics(style: 'light' | 'medium' | 'heavy'): void
  pickImage(opts?: { source?: 'camera' | 'library' }): Promise<Blob | null>
}

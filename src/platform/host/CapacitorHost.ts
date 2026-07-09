// CapacitorHost — нативная реализация AgOSHost (EngSpec §2.2/§4, ARS-150 / S4).
// ЕДИНСТВЕННОЕ место, где живут @capacitor/* импорты (ревью-инвариант §10:
// `grep '@capacitor/'` вне platform/host/ = нарушение). Ядро зовёт только AgOSHost.
//
// Модуль подгружается ДИНАМИЧЕСКИ из HostContext лишь когда detectHostKind()==='capacitor'
// — весь Capacitor-граф попадает в отдельный чанк, web-бандл его не тянет (3G-бюджет Dok6).

import { Capacitor } from '@capacitor/core'
import { App as CapApp } from '@capacitor/app'
import { Preferences } from '@capacitor/preferences'
import { Network } from '@capacitor/network'
import { StatusBar, Style } from '@capacitor/status-bar'
import { SplashScreen } from '@capacitor/splash-screen'
import { Haptics, ImpactStyle } from '@capacitor/haptics'
import { Camera, CameraResultType, CameraSource } from '@capacitor/camera'
import { PushNotifications } from '@capacitor/push-notifications'
import { supabase } from '@/lib/supabase'
import type { AgOSHost, PushToken } from './AgOSHost'
import type { KVStorage } from '@/platform/storage'
import { setAppStorageBackend, setDraftStorageBackend } from '@/platform/storage'
import { setNetworkBackend } from '@/platform/network'

// URL нативной ссылки → path приложения ('/cabinet/batch/:id'). Универсальная ссылка
// https://app.turanstandard.kz/cabinet/... и fallback-схема agos://cabinet/... сводятся
// к path+search+hash (маппинг path→экран — общий с §3, обрабатывает роутер).
function urlToPath(raw: string): string | null {
  try {
    const u = new URL(raw)
    const path = u.pathname + u.search + u.hash
    return path.startsWith('/') ? path : '/' + path
  } catch {
    return null
  }
}

// Preferences-бэкенд для platform/storage: secure-хранилище переживает чистку WebView ОС
// (EngSpec §4). Sync-контракт KVStorage сохраняем через прогретый in-memory кеш +
// write-through в Preferences. Кеш гидратируется ДО монтирования AuthProvider
// (HostProvider ждёт createCapacitorHost) — supabase-js читает уже тёплое хранилище.
async function installPreferencesStorage(): Promise<void> {
  const cache = new Map<string, string>()
  try {
    const { keys } = await Preferences.keys()
    await Promise.all(
      keys.map(async (k) => {
        const { value } = await Preferences.get({ key: k })
        if (value != null) cache.set(k, value)
      }),
    )
  } catch {
    /* первый запуск / хранилище пусто — кеш стартует пустым */
  }
  const backend: KVStorage = {
    getItem: (k) => (cache.has(k) ? (cache.get(k) as string) : null),
    setItem: (k, v) => {
      cache.set(k, v)
      void Preferences.set({ key: k, value: v })
    },
    removeItem: (k) => {
      cache.delete(k)
      void Preferences.remove({ key: k })
    },
  }
  // Персистентный и черновиковый скоупы на нативке оба секьюрные (черновик визарда
  // переживает рестарт — §4). Ключи agos.* и черновика не пересекаются — один backend ок.
  setAppStorageBackend(backend)
  setDraftStorageBackend(backend)
}

// Реальный сетевой статус через @capacitor/network (EngSpec §4). Подменяет
// navigator.onLine-бэкенд S3 — OfflineBar/офлайн-гейт получают нативную правду.
function installNetwork(): void {
  let online = true
  const listeners = new Set<() => void>()
  void Network.getStatus().then((s) => {
    online = s.connected
    listeners.forEach((l) => l())
  })
  void Network.addListener('networkStatusChange', (s) => {
    online = s.connected
    listeners.forEach((l) => l())
  })
  setNetworkBackend({
    isOnline: () => online,
    subscribe: (l) => {
      listeners.add(l)
      return () => {
        listeners.delete(l)
      }
    },
  })
}

// Статус-бар (§8 «цвет статус-бара») + клавиатура. Форсируем в рантайме — переживает
// смену темы WebView. Style.Light = ТЁМНЫЙ контент на светлом фоне (iOS-нейминг).
async function configureChrome(): Promise<void> {
  try {
    await StatusBar.setStyle({ style: Style.Light })
    if (Capacitor.getPlatform() === 'android') {
      await StatusBar.setBackgroundColor({ color: '#fdf6ee' })
      await StatusBar.setOverlaysWebView({ overlay: false })
    }
  } catch {
    /* StatusBar недоступен (напр. планшет без бара) — no-op */
  }
}

export async function createCapacitorHost(): Promise<AgOSHost> {
  // Порядок важен: хранилище прогревается ДО чтения сессии supabase-js (см. §4).
  await installPreferencesStorage()
  installNetwork()
  void configureChrome()

  // Deep-link cold-start: ловим стартовый URL и ранние appUrlOpen в буфер, пока
  // ядро (§6, S5-роутер) не подпишется через onDeepLink — иначе холодная ссылка теряется.
  let pendingDeepLink: string | null = null
  let deepLinkHandler: ((path: string) => void) | null = null
  const emitDeepLink = (path: string | null) => {
    if (!path) return
    if (deepLinkHandler) deepLinkHandler(path)
    else pendingDeepLink = path
  }
  try {
    const launch = await CapApp.getLaunchUrl()
    if (launch?.url) emitDeepLink(urlToPath(launch.url))
  } catch {
    /* нет стартового URL */
  }
  void CapApp.addListener('appUrlOpen', (e) => emitDeepLink(urlToPath(e.url)))

  // Deep-link из тапа по push (S5.3 / ARS-155): payload несёт целевой path (контракт C6 / ARS-144).
  // Пустой/неизвестный payload → home '/cabinet', без краша (роутер разрулит §6 шаг 5).
  void PushNotifications.addListener('pushNotificationActionPerformed', (action) => {
    const data = action.notification.data as { path?: string; link?: string } | undefined
    const raw = data?.path ?? data?.link
    if (!raw) {
      emitDeepLink('/cabinet')
      return
    }
    emitDeepLink(raw.startsWith('/') ? raw : urlToPath(raw))
  })

  // Сплэш держался launchAutoHide:false — прячем, когда нативный слой готов.
  void SplashScreen.hide()

  let pushHandler: ((token: PushToken) => void) | null = null

  // iOS → APNs, Android → FCM (EngSpec §6, соответствует CHECK push_token / ARS-139).
  const toPushToken = (value: string): PushToken => {
    const p = Capacitor.getPlatform()
    const platform = p === 'ios' ? 'ios' : 'android'
    return { token: value, platform, provider: platform === 'ios' ? 'apns' : 'fcm' }
  }

  const host: AgOSHost = {
    kind: 'capacitor',

    async bootstrapSession() {
      // Сессия восстанавливается из прогретого Preferences-хранилища самим supabase-js
      // (installPreferencesStorage уже отработал) — явная инъекция не нужна, как на web.
      return null
    },

    async signOut() {
      // supabase.signOut() удаляет sb-*-auth-token → наш backend.removeItem → Preferences.remove.
      // Секьюрное хранилище чистится автоматически, отдельный проход не нужен.
      await supabase.auth.signOut()
    },

    async registerPushToken() {
      // Клиентская часть S5 (§6): получаем нативный APNs/FCM-токен и отдаём ядру с
      // provider/platform; привязку токен→БД (rpc_register_push_token) делает ядро.
      try {
        const perm = await PushNotifications.requestPermissions()
        if (perm.receive !== 'granted') return null
        return await new Promise<PushToken | null>((resolve) => {
          let settled = false
          const finish = (v: PushToken | null) => {
            if (settled) return
            settled = true
            resolve(v)
          }
          void PushNotifications.addListener('registration', (t) => {
            const pt = toPushToken(t.value)
            if (pushHandler) pushHandler(pt)
            finish(pt)
          })
          void PushNotifications.addListener('registrationError', () => finish(null))
          void PushNotifications.register()
          setTimeout(() => finish(null), 10_000)
        })
      } catch {
        return null
      }
    },

    onPushToken(handler) {
      pushHandler = handler
    },

    onDeepLink(handler) {
      deepLinkHandler = handler
      if (pendingDeepLink) {
        handler(pendingDeepLink)
        pendingDeepLink = null
      }
    },

    caps: { haptics: true, camera: true, secureStorage: true, statusBar: true },

    haptics(style) {
      const map = { light: ImpactStyle.Light, medium: ImpactStyle.Medium, heavy: ImpactStyle.Heavy }
      void Haptics.impact({ style: map[style] }).catch(() => {})
    },

    async pickImage(opts) {
      try {
        const source =
          opts?.source === 'library'
            ? CameraSource.Photos
            : opts?.source === 'camera'
              ? CameraSource.Camera
              : CameraSource.Prompt
        const photo = await Camera.getPhoto({
          resultType: CameraResultType.Uri,
          source,
          quality: 80,
          correctOrientation: true,
        })
        if (!photo.webPath) return null
        const res = await fetch(photo.webPath)
        return await res.blob()
      } catch {
        // отмена пользователем / нет доступа — как на web (null)
        return null
      }
    },
  }

  return host
}

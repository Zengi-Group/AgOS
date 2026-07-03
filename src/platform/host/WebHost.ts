import { supabase } from '@/lib/supabase'
import type { AgOSHost } from './AgOSHost'

// WebHost — браузер / PWA (EngSpec §2.2). No-op мост:
// сессию персистит сам supabase-js (localStorage), deep-link = обычный URL.
export function createWebHost(): AgOSHost {
  return {
    kind: 'web',

    async bootstrapSession() {
      // supabase-js сам восстанавливает сессию из localStorage — инъекция не нужна.
      return null
    },

    async signOut() {
      await supabase.auth.signOut()
    },

    async registerPushToken() {
      // Web Push — опционально, вне скоупа S1 (push-клиент = S5, бэкенд = C-серия).
      return null
    },

    onPushToken() {
      // Токенов на web нет — подписка no-op.
    },

    onDeepLink() {
      // Deep-link на web = обычная URL-навигация, её обрабатывает react-router.
    },

    caps: { haptics: false, camera: false, secureStorage: false, statusBar: false },

    haptics() {
      // no-op в браузере
    },

    pickImage(opts) {
      return new Promise(resolve => {
        const input = document.createElement('input')
        input.type = 'file'
        input.accept = 'image/*'
        if (opts?.source === 'camera') input.capture = 'environment'
        input.onchange = () => resolve(input.files?.[0] ?? null)
        // cancel не даёт события во всех браузерах — отдаём null при возврате фокуса
        input.oncancel = () => resolve(null)
        input.click()
      })
    },
  }
}

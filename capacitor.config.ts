import type { CapacitorConfig } from '@capacitor/cli'

// AgOS · S4 Capacitor-упаковка (EngSpec §8, ARS-150).
// Единый Vite-билд (webDir=dist) под iOS/Android. Нативный бандл собирается
// `npm run build:native` (VITE_APP_TARGET=native → только /cabinet + /mpk + auth).
// appId = bundle id для App Store / Play; менять НЕЛЬЗЯ после первой публикации.
const config: CapacitorConfig = {
  appId: 'kz.turan.agos',
  appName: 'AgOS · TURAN',
  webDir: 'dist',

  // Deep links (§8, ARS-150): универсальные ссылки (iOS) / app links (Android) не
  // требуют кастомной схемы — открываются https://app.turanstandard.kz/cabinet/...
  // (домен регистрируется в apple-app-site-association / assetlinks.json).
  // Кастомная схема agos:// оставлена как fallback для push-navigation вне https.
  server: {
    androidScheme: 'https',
    iosScheme: 'https',
  },

  plugins: {
    // Сплэш держится, пока JS не смонтировал первый кадр (HostProvider резолвит
    // CapacitorHost асинхронно) — прячется вручную в CapacitorHost.
    SplashScreen: {
      launchShowDuration: 0,
      launchAutoHide: false,
      backgroundColor: '#fdf6ee',
      androidSplashResourceName: 'splash',
      showSpinner: false,
    },
    // Статус-бар (§8 «цвет статус-бара»): тёплый фон кабинета, тёмные иконки.
    // Стиль/цвет также форсируется рантаймом в CapacitorHost (переживает тему WebView).
    StatusBar: {
      style: 'LIGHT', // Style.Light = ТЁМНЫЙ текст на светлом фоне (iOS-нейминг)
      backgroundColor: '#f6f3ed', // = --bg кабинета (L5, аудит 2026-07-13): убираем Android-шов статус-бар↔контент
      overlaysWebView: false,
    },
    Keyboard: {
      resize: 'native',
    },
    // Push (§6, C-серия) — клиентская регистрация в S5; плагин на борту уже для
    // S4 (Apple 4.2 risk-чеклист: push присутствует в сборке).
    PushNotifications: {
      presentationOptions: ['badge', 'sound', 'alert'],
    },
  },
}

export default config

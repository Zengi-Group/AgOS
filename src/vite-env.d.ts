/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string
  readonly VITE_SUPABASE_ANON_KEY: string
  // App-target (EngSpec §8, ARS-150): 'native' = сборка под iOS/Android (только
  // /cabinet + /mpk + auth); отсутствует/иное = web-таргет (полное приложение).
  readonly VITE_APP_TARGET?: 'native' | 'web'
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

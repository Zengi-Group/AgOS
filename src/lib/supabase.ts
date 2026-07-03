import { createClient } from '@supabase/supabase-js'
import { authStorage } from '@/platform/storage'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  console.warn(
    'VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set in .env'
  )
}

export const supabase = createClient(
  supabaseUrl || 'https://placeholder.supabase.co',
  supabaseAnonKey || 'placeholder-key',
  {
    // S3 (ARS-149, EngSpec §4): сессия через platform/storage. Web = localStorage
    // (тот же sb-*-auth-token ключ, поведение 1:1 с дефолтом supabase-js);
    // нативка (S4) подменяет бэкенд на secure Preferences — сессия переживает чистку WebView.
    auth: { storage: authStorage },
  }
)

import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useHost } from '@/platform/host/HostContext'

// S5/ARS-155: тап по push-уведомлению открывает целевой экран (EngSpec §6 шаг 5).
// Хост (CapacitorHost.onDeepLink / cold-start буфер) отдаёт path вида '/cabinet/batch/:id';
// верхний react-router навигирует, вложенный IonReactRouter (/cabinet/*) подхватывает подпуть.
// WebHost.onDeepLink = no-op (deep-link на web = обычный URL) → компонент безвреден на web.
export function PushDeepLinkBridge() {
  const host = useHost()
  const navigate = useNavigate()
  useEffect(() => {
    host.onDeepLink((path) => navigate(path))
  }, [host, navigate])
  return null
}

// AgOS · DEBT-NATIVE-ROUTER-01 · Граница истории v5-острова оболочек (фермер /cabinet, МПК /mpk).
// Проблема: v5-остров (@ionic/react-router) делит ОДНУ браузерную историю с внешним v6-роутером
// и не имеет нижней границы. Системный «назад» — Android edge-swipe слева-направо, аппаратная
// кнопка (Capacitor App plugin по умолчанию → window.history.back()), browser-back — уводил
// авторизованного фермера НИЖЕ корня оболочки, где лежат pre-mount auth-записи (/welcome,
// /login). Выход туда выглядел как разлогин (ARS · farmer-swipe-logout).
//
// Фикс: постоянный слушатель popstate на уровне App (НЕ размонтируется при уходе из оболочки —
// иначе v6 синхронно снимает слушатель прежде, чем тот отработает). Когда back увёл
// авторизованного пользователя, только что бывшего в оболочке, на не-оболочечный путь —
// возвращаем в оболочку. Программный logout идёт через navigate() (не popstate) и обнуляет
// session — под гард не попадает.
//
// Слушатель регистрируется ОДИН раз (deps []), а session/navigate читаются через ref: иначе
// меняющаяся идентичность navigate/session пересоздаёт эффект и в момент popstate слушателя
// может не оказаться в списке (гонка снятия/добавления).
import { useEffect, useRef } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'

// Пути оболочек с независимой историей v5-острова.
const SHELL_RE = /^\/(cabinet|mpk)(\/|$)/

export function ShellBackGuard() {
  const { session } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const lastShell = useRef<string | null>(null)
  const sessionRef = useRef(session)
  const navigateRef = useRef(navigate)
  sessionRef.current = session
  navigateRef.current = navigate

  // Запоминаем последний путь внутри оболочки — на него и возвращаем при перехвате.
  useEffect(() => {
    if (SHELL_RE.test(location.pathname)) lastShell.current = location.pathname
  }, [location.pathname])

  useEffect(() => {
    const onPop = () => {
      if (!sessionRef.current) return                        // не авторизован — обычная навигация
      if (SHELL_RE.test(window.location.pathname)) return    // остались в оболочке — no-op
      const target = lastShell.current
      if (!target) return                                    // пользователь ни разу не был в оболочке
      navigateRef.current(target, { replace: true })
    }
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  return null
}

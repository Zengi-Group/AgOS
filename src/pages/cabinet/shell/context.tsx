// AgOS · Этап 1 · Контекст оболочки. Глобальное состояние без prop-drilling.

import { createContext, useContext } from 'react'
import type { ShellContextValue } from './types'

export const ShellCtx = createContext<ShellContextValue | null>(null)

export function useShell(): ShellContextValue {
  const ctx = useContext(ShellCtx)
  if (!ctx) throw new Error('useShell must be used within ShellProvider')
  return ctx
}

// AgOS · Этап 1 · Иконки оболочки (lucide-геометрия, stroke 1.8, без эмодзи).
// Пути — слово в слово из прототипа shell/ui.jsx.

import type { ReactElement } from 'react'

type IconKey =
  | 'home' | 'farm' | 'market' | 'chat' | 'cabinet' | 'mic' | 'send'
  | 'tag' | 'percent' | 'grid' | 'wheat' | 'cross' | 'tractor' | 'tool'
  | 'vet' | 'bag' | 'check' | 'chev'

const PATHS: Record<IconKey, ReactElement> = {
  home: <g><path d="M4 11l8-7 8 7" /><path d="M6 9.5V20h12V9.5" /></g>,
  farm: <g><path d="M3 20h18" /><path d="M5 20v-8l7-5 7 5v8" /><path d="M9 20v-5h6v5" /></g>,
  market: <g><path d="M4 8l1.5-4h13L20 8" /><path d="M4 8h16v3a2.5 2.5 0 0 1-5 0 2.6 2.6 0 0 1-6 0 2.5 2.5 0 0 1-5 0z" /><path d="M6 13.5V20h12v-6.5" /></g>,
  chat: <g><path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5 8.4 8.4 0 0 1-3.8-.9L4 20l.9-4.7A8.5 8.5 0 1 1 21 11.5z" /></g>,
  cabinet: <g><circle cx="12" cy="8" r="4" /><path d="M4 20c1.5-3.5 4.5-5 8-5s6.5 1.5 8 5" /></g>,
  mic: <g><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0" /><path d="M12 18v3" /></g>,
  send: <g><path d="M4 12l16-8-6 16-2.5-6.5z" /></g>,
  tag: <g><path d="M3 12l9-9 9 5-2 10-9 4z" transform="rotate(8 12 12)" /><circle cx="12" cy="9" r="1.6" /></g>,
  percent: <g><path d="M5 19L19 5" /><circle cx="7" cy="7" r="2.6" /><circle cx="17" cy="17" r="2.6" /></g>,
  grid: <g><rect x="4" y="4" width="7" height="7" rx="1.5" /><rect x="13" y="4" width="7" height="7" rx="1.5" /><rect x="4" y="13" width="7" height="7" rx="1.5" /><rect x="13" y="13" width="7" height="7" rx="1.5" /></g>,
  wheat: <g><path d="M12 21V8" /><path d="M12 12c-3 0-5-2-5-5 3 0 5 2 5 5z" /><path d="M12 12c3 0 5-2 5-5-3 0-5 2-5 5z" /><path d="M12 7c-2.5 0-4-1.7-4-4 2.5 0 4 1.7 4 4z" /></g>,
  cross: <g><path d="M9 4h6v5h5v6h-5v5H9v-5H4V9h5z" /></g>,
  tractor: <g><circle cx="7" cy="16" r="3.5" /><circle cx="18" cy="17" r="2.5" /><path d="M10.5 16H15M4.5 13l1-6h7l1.5 6" /><path d="M16 13V9h3l1.5 4" /></g>,
  tool: <g><path d="M14 4a4.5 4.5 0 0 0-4.3 5.9L4 15.6V20h4.4l5.7-5.7A4.5 4.5 0 0 0 20 10z" /></g>,
  vet: <g><path d="M6 3v6a4.5 4.5 0 0 0 9 0V3" /><path d="M4 3h3M13 3h3" /><path d="M10.5 13.5V16a3.5 3.5 0 0 0 7 0v-1" /><circle cx="17.5" cy="14.5" r="2" /></g>,
  bag: <g><path d="M6 8h12l-1 12H7z" /><path d="M9 8V6a3 3 0 0 1 6 0v2" /></g>,
  check: <g><path d="M4 12l5 5L20 6" /></g>,
  chev: <g><path d="M9 5l7 7-7 7" /></g>,
}

export function ShIc({ k, size }: { k: IconKey; size?: number }) {
  const s = size || 17
  return (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {PATHS[k]}
    </svg>
  )
}

export type { IconKey }

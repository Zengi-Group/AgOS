/**
 * Единые токены для экранов входа: /register, /login, /membership и PhonePicker.
 * Портировано из прототипа agos-farmer (src/lib/auth-ui/tokens.ts) — светлая
 * «бумажная» тема. Меняем цвет/шрифт — здесь, в одном месте.
 *
 * Скоуп — только вход-фаннел; глобальный :root (лендинг/админка) НЕ трогаем.
 */
export const T = {
  bg: '#fafaf7',
  bgS: '#f2efe9',
  bgC: '#ffffff',
  bgM: '#efece5',
  fg: '#141312',
  fg2: '#5c574f',
  fg3: '#8f8a82',
  bd: '#e6e2d9',
  bdS: '#ece8df',
  bdH: '#d4cec3',
  accent: '#B8710A',
  cta: '#141312',
  ctaFg: '#fafaf7',
  red: '#c2402f',
  green: '#3f9d5c',
  blue: '#3d7fd6',
  font: "'Geist', -apple-system, BlinkMacSystemFont, system-ui, sans-serif",
  mono: "'Geist Mono', ui-monospace, SFMono-Regular, monospace",
} as const

export type Tokens = typeof T

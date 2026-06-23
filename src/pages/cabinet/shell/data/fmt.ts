// AgOS · Этап 2 · Форматирование и даты. Перенесено из прототипа p1/data.jsx (слово в слово).

export const NBSP = ' '

const MON_SHORT = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек']
const MON_GEN = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря']

export function fmtMoney(n: number): string {
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, NBSP)
}
export function fmtD(d: Date): string { return d.getDate() + ' ' + MON_SHORT[d.getMonth()] }
export function fmtDGen(d: Date): string { return d.getDate() + ' ' + MON_GEN[d.getMonth()] }
export function addDays(d: Date, n: number): Date { const x = new Date(d); x.setDate(x.getDate() + n); return x }
export function monthEnd(d: Date): Date { return new Date(d.getFullYear(), d.getMonth() + 1, 0) }

export const TODAY = new Date()

// русские множественные формы (shell/data.jsx)
export const ruPlural = (n: number, one: string, few: string, many: string): string =>
  n % 10 === 1 && n % 100 !== 11 ? one
    : n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? few : many

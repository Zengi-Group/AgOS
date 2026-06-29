// Казахстанский номер: ввод и нормализация.
// Отображение: «+7 771 085 6566» (группы 3-3-4).
// Нормализация для бэкенда: '+7XXXXXXXXXX' (E.164) либо null, если номер неполный.

/** Форматирует ввод в маску «+7 771 085 6566». */
export function formatPhoneKz(value: string): string {
  let d = value.replace(/\D/g, '')
  if (d.startsWith('8')) d = '7' + d.slice(1)
  if (!d.startsWith('7')) d = '7' + d
  d = d.slice(0, 11) // 7 + 10 цифр
  const rest = d.slice(1)
  let out = '+7'
  if (rest.length > 0) out += ' ' + rest.slice(0, 3)
  if (rest.length > 3) out += ' ' + rest.slice(3, 6)
  if (rest.length > 6) out += ' ' + rest.slice(6, 10)
  return out
}

/** Возвращает '+7XXXXXXXXXX' или null, если номер некорректен/неполон. */
export function normalizePhoneKz(value: string): string | null {
  let d = value.replace(/\D/g, '')
  if (d.startsWith('8')) d = '7' + d.slice(1)
  if (d.length === 10) d = '7' + d
  if (d.length !== 11 || !d.startsWith('7')) return null
  return '+' + d
}

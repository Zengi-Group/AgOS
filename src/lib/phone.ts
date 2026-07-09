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

// ── Международный номер (E.164) — для вход-фаннела с PhonePicker ──

import { parsePhoneNumber } from 'libphonenumber-js'

/**
 * Маскирует E.164-номер для показа на экране OTP/PIN: международный формат
 * с скрытыми последними 4 цифрами, напр. «+7 700 123 ••-••». Страна-агностично.
 */
export function maskPhoneE164(e164: string): string {
  try {
    const p = parsePhoneNumber(e164)
    if (p) {
      const s = p.formatInternational()
      let hidden = 0
      return s
        .split('')
        .reverse()
        .map((ch) => (/\d/.test(ch) && hidden < 4 ? (hidden++, '•') : ch))
        .reverse()
        .join('')
    }
  } catch {
    /* неполный/некорректный — возвращаем как есть */
  }
  return e164
}

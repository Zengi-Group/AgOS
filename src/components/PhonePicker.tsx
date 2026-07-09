/**
 * PhonePicker — международное поле телефона для вход-фаннела (/register, /login).
 *
 * Значение наружу — всегда E.164 («+77001234567»). Страна по умолчанию — KZ,
 * так что для казахстанского номера E.164 == прежний контракт `+7` + 10 цифр
 * (бэкенду bird-otp / rpc_register_organization уходит байт-в-байт то же самое).
 *
 * Внутри:
 *  · Форматирование на лету — AsYouType(country).input(digits) (libphonenumber-js),
 *    маска перестраивается под страну.
 *  · Валидация — getNumber()?.isPossible() → авто-blur + onComplete при полном номере.
 *  · Пикер страны — bottom-sheet: приоритетный блок (СНГ+) → разделитель → алфавит;
 *    поиск по русскому имени / ISO-коду / calling-коду. Локаль ru.json.
 *
 * Дизайн-токены — из auth-ui/tokens (светлая «бумажная» тема вход-фаннела).
 */
import { useEffect, useMemo, useRef, useState } from 'react'
import {
  AsYouType,
  getCountries,
  getCountryCallingCode,
  parsePhoneNumber,
  type CountryCode,
} from 'libphonenumber-js'
import flagsRaw from 'react-phone-number-input/flags'
import ruLocaleRaw from 'react-phone-number-input/locale/ru.json'
import { T } from '@/lib/auth-ui/tokens'

// Типы пакета ключуются по его собственному `Country`, а не по `CountryCode`
// из libphonenumber-js → приводим к строковым мапам для индексации.
type FlagCmp = React.ComponentType<{
  title?: string
  style?: React.CSSProperties
  preserveAspectRatio?: string
}>
const flags = flagsRaw as unknown as Record<string, FlagCmp | undefined>
const ruLocale = ruLocaleRaw as unknown as Record<string, string>

// Приоритетные страны — вверху списка (СНГ + соседи + частые).
const PRIORITY: CountryCode[] = [
  'KZ', 'RU', 'KG', 'UZ', 'BY', 'TJ', 'TM', 'AZ', 'GE', 'AM', 'UA', 'TR', 'CN',
]
const PRIORITY_SET = new Set<string>(PRIORITY)

const ALL_COUNTRIES = getCountries()

function countryName(c: CountryCode): string {
  return ruLocale[c] ?? c
}

/** Круглый флаг фиксированного размера (cover-обрезка, без искажений). */
function Flag({ country, size = 24 }: { country: CountryCode; size?: number }) {
  const Cmp = flags[country]
  return (
    <span
      style={{
        width: size,
        height: size,
        flexShrink: 0,
        borderRadius: 999,
        overflow: 'hidden',
        display: 'inline-grid',
        placeItems: 'center',
        background: T.bgM,
        boxShadow: `inset 0 0 0 0.5px ${T.bd}`,
      }}
    >
      {Cmp ? (
        <Cmp
          title=""
          style={{ width: '100%', height: '100%', display: 'block' }}
          preserveAspectRatio="xMidYMid slice"
        />
      ) : (
        <span style={{ fontSize: 10, color: T.fg3, fontFamily: T.mono }}>{country}</span>
      )}
    </span>
  )
}

interface PhonePickerProps {
  /** E.164, напр. «+77001234567». Пустая строка — поле пустое. */
  value: string
  onChange: (value: string) => void
  /** Вызывается один раз, когда номер стал «возможным» (полный). */
  onComplete?: () => void
  autoFocus?: boolean
  error?: boolean
  disabled?: boolean
}

export function PhonePicker({
  value,
  onChange,
  onComplete,
  autoFocus,
  error,
  disabled,
}: PhonePickerProps) {
  const [country, setCountry] = useState<CountryCode>('KZ')
  const [focused, setFocused] = useState(false)
  const [sheetOpen, setSheetOpen] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const completedRef = useRef(false)

  // ── Инициализация страны из входящего E.164 (один раз, если номер уже есть) ──
  const didInit = useRef(false)
  useEffect(() => {
    if (didInit.current) return
    didInit.current = true
    if (!value) return
    try {
      const parsed = parsePhoneNumber(value)
      if (parsed?.country) setCountry(parsed.country)
    } catch {
      /* неполный номер — оставляем KZ */
    }
  }, [value])

  const callingCode = getCountryCallingCode(country)

  // Национальные цифры = E.164 без «+» и без кода страны.
  const nationalDigits = useMemo(() => {
    const raw = value.replace(/\D/g, '')
    return raw.startsWith(callingCode) ? raw.slice(callingCode.length) : raw
  }, [value, callingCode])

  const formatted = useMemo(
    () => new AsYouType(country).input(nationalDigits),
    [country, nationalDigits]
  )

  const maxNational = Math.max(0, 15 - callingCode.length)

  const emit = (digits: string, forCountry: CountryCode) => {
    const cc = getCountryCallingCode(forCountry)
    const clean = digits.replace(/\D/g, '').slice(0, Math.max(0, 15 - cc.length))
    onChange(clean ? `+${cc}${clean}` : '')

    // Авто-blur при полном номере — один раз.
    const ayt = new AsYouType(forCountry)
    ayt.input(clean)
    const num = ayt.getNumber()
    if (num?.isPossible()) {
      if (!completedRef.current) {
        completedRef.current = true
        setTimeout(() => inputRef.current?.blur(), 80)
        onComplete?.()
      }
    } else {
      completedRef.current = false
    }
  }

  const handleInput = (e: React.ChangeEvent<HTMLInputElement>) => {
    emit(e.target.value.replace(/\D/g, '').slice(0, maxNational), country)
  }

  const pickCountry = (c: CountryCode) => {
    setCountry(c)
    setSheetOpen(false)
    completedRef.current = false
    emit(nationalDigits, c) // сохранить набранные цифры под новым кодом
    setTimeout(() => inputRef.current?.focus(), 60)
  }

  const borderColor = error ? T.red : focused ? T.fg : T.bd

  return (
    <>
      <div
        style={{
          display: 'flex',
          alignItems: 'stretch',
          height: 52,
          background: T.bgC,
          border: `1px solid ${borderColor}`,
          borderRadius: 12,
          overflow: 'hidden',
          transition: 'border-color 80ms',
          opacity: disabled ? 0.5 : 1,
        }}
      >
        {/* Селектор страны: флаг + calling-код + шеврон */}
        <button
          type="button"
          onClick={() => !disabled && setSheetOpen(true)}
          disabled={disabled}
          aria-label="Выбрать страну"
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            padding: '0 12px 0 14px',
            background: 'transparent',
            border: 'none',
            borderRight: `1px solid ${T.bdS}`,
            cursor: disabled ? 'default' : 'pointer',
            fontFamily: T.font,
            color: T.fg,
            WebkitTapHighlightColor: 'transparent',
          }}
        >
          <Flag country={country} />
          <span style={{ fontSize: 17, fontWeight: 500, letterSpacing: '-0.01em' }}>
            +{callingCode}
          </span>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke={T.fg3} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
            <path d="M6 9l6 6 6-6" />
          </svg>
        </button>

        <input
          ref={inputRef}
          type="tel"
          inputMode="tel"
          autoFocus={autoFocus}
          disabled={disabled}
          value={formatted}
          onChange={handleInput}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          placeholder="Номер телефона"
          style={{
            flex: 1,
            minWidth: 0,
            height: '100%',
            padding: '0 14px',
            background: 'transparent',
            border: 'none',
            outline: 'none',
            color: T.fg,
            fontFamily: T.font,
            fontSize: 17,
            fontWeight: 500,
            letterSpacing: '-0.01em',
          }}
        />
      </div>

      {sheetOpen && (
        <CountrySheet
          current={country}
          onPick={pickCountry}
          onClose={() => setSheetOpen(false)}
        />
      )}
    </>
  )
}

/* ── Bottom-sheet выбора страны ─────────────────────────────────────────── */
function CountrySheet({
  current,
  onPick,
  onClose,
}: {
  current: CountryCode
  onPick: (c: CountryCode) => void
  onClose: () => void
}) {
  const [q, setQ] = useState('')
  const searchRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    searchRef.current?.focus()
  }, [])

  const query = q.trim().toLowerCase()
  const matches = (c: CountryCode) => {
    if (!query) return true
    const name = countryName(c).toLowerCase()
    const cc = getCountryCallingCode(c)
    return (
      name.includes(query) ||
      c.toLowerCase().includes(query) ||
      cc.includes(query.replace('+', ''))
    )
  }

  const priority = PRIORITY.filter(matches)
  const rest = ALL_COUNTRIES
    .filter((c) => !PRIORITY_SET.has(c))
    .filter(matches)
    .sort((a, b) => countryName(a).localeCompare(countryName(b), 'ru'))

  const Row = ({ c }: { c: CountryCode }) => (
    <button
      type="button"
      onClick={() => onPick(c)}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        width: '100%',
        padding: '12px 20px',
        background: c === current ? T.bgS : 'transparent',
        border: 'none',
        cursor: 'pointer',
        textAlign: 'left',
        fontFamily: T.font,
        color: T.fg,
        WebkitTapHighlightColor: 'transparent',
      }}
    >
      <Flag country={c} />
      <span style={{ flex: 1, fontSize: 16, letterSpacing: '-0.01em', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
        {countryName(c)}
      </span>
      <span style={{ fontSize: 15, color: T.fg3, fontFamily: T.mono }}>+{getCountryCallingCode(c)}</span>
    </button>
  )

  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 50,
        background: 'rgba(20,19,18,0.32)',
        display: 'flex',
        alignItems: 'flex-end',
        justifyContent: 'center',
        WebkitBackdropFilter: 'blur(2px)',
        backdropFilter: 'blur(2px)',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: '100%',
          maxWidth: 480,
          height: '85vh',
          background: T.bg,
          borderTopLeftRadius: 20,
          borderTopRightRadius: 20,
          display: 'flex',
          flexDirection: 'column',
          overflow: 'hidden',
          paddingBottom: 'env(safe-area-inset-bottom)',
        }}
      >
        {/* Хват + заголовок + поиск */}
        <div style={{ padding: '10px 20px 12px', borderBottom: `0.5px solid ${T.bdS}` }}>
          <div style={{ width: 36, height: 4, borderRadius: 999, background: T.bdH, margin: '0 auto 14px' }} />
          <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: '-0.01em', marginBottom: 12 }}>
            Выберите страну
          </div>
          <input
            ref={searchRef}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Поиск — страна или код"
            style={{
              width: '100%',
              height: 44,
              padding: '0 14px',
              background: T.bgC,
              border: `1px solid ${T.bd}`,
              borderRadius: 10,
              outline: 'none',
              color: T.fg,
              fontFamily: T.font,
              fontSize: 16,
              boxSizing: 'border-box',
            }}
          />
        </div>

        {/* Список */}
        <div style={{ flex: 1, overflowY: 'auto', paddingBottom: 12 }}>
          {priority.length > 0 && (
            <>
              {priority.map((c) => <Row key={c} c={c} />)}
              {rest.length > 0 && (
                <div style={{ height: 1, background: T.bdS, margin: '8px 20px' }} />
              )}
            </>
          )}
          {rest.map((c) => <Row key={c} c={c} />)}
          {priority.length === 0 && rest.length === 0 && (
            <div style={{ padding: '32px 20px', textAlign: 'center', color: T.fg3, fontSize: 15 }}>
              Ничего не найдено
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

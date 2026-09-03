// AgOS · Slice10 · SCR-P0 — честные состояния оболочки: заглушка раздела, скелет загрузки,
// ошибка чтения. Все три обязаны показывать правду, а не имитировать данные (FR-008).

import { PhIcon, type PhIconName } from '../../components/icons/PhIcon'

// M-015: первый рендер раздела — скелет, а не белый провал.
export function ConsoleSkeleton() {
  return (
    <div className="mpkc-skel" aria-busy="true" aria-label="Загрузка раздела">
      <div className="mpkc-skel-row" />
      <div className="mpkc-skel-row" />
      <div className="mpkc-skel-row" />
    </div>
  )
}

// M-014: честный текст + retry. Техническая деталь уходит в console.error у вызывающего —
// сырой текст SDK пользователю не показываем (урок IDENTITY-14).
export function ConsoleError({ onRetry }: { onRetry: () => void }) {
  return (
    <div className="mpkc-stub">
      <PhIcon name="wifiSlash" size={40} />
      <div className="mpkc-stub-title">Не удалось загрузить данные предприятия</div>
      <div className="mpkc-stub-note">
        Проверьте соединение и повторите. Если не помогает — раздел доступен в мобильном
        кабинете МПК.
      </div>
      <button type="button" className="mpkc-stub-act" onClick={onRetry}>Повторить</button>
    </div>
  )
}

interface SectionStubProps {
  title: string
  note: string
  icon?: PhIconName
  action?: { label: string; onClick: () => void }
}

// FR-013 · FR-008: раздел, которого на десктопе ещё нет, называет своё состояние и
// существующий обходной путь. Ни одного выдуманного числа.
export function SectionStub({ title, note, icon = 'clock', action }: SectionStubProps) {
  return (
    <div className="mpkc-stub">
      <PhIcon name={icon} size={40} />
      <div className="mpkc-stub-title">{title}</div>
      <div className="mpkc-stub-note">{note}</div>
      {action && (
        <button type="button" className="mpkc-stub-act" onClick={action.onClick}>{action.label}</button>
      )}
    </div>
  )
}

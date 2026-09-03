// AgOS · Slice10 · SCR-P0 — ptabs профиля: шесть подразделов (§3.5 выписки прототипа).
// Порт HeaderTabs дизайн-системы: подчёркивание активного цветом --cta, иконка + подпись.
// Счётчики (`count`) прототипа появятся вместе со своими разделами (MP-3.3/3.5/3.9) —
// пока их нечем считать, а рисовать нули значило бы имитировать данные (FR-008).

import { MPK_PROFILE_TABS, type MpkProfileTab } from '../types'
import { PhIcon, type PhIconName } from '../../components/icons/PhIcon'

// Подписи и иконки. Тип `Record<MpkProfileTab, …>` — компиляторная гарантия, что вкладка
// есть у каждого слага (P4: порядок вкладок живёт в одном месте — MPK_PROFILE_TABS).
// Начертания сведены к набору PhIcon (§13.1): star → starOutline, shield → shieldCheck,
// messageCircle → chat.
const TAB_META: Record<MpkProfileTab, { label: string; icon: PhIconName }> = {
  overview: { label: 'Обзор', icon: 'dashboard' },
  org: { label: 'Предприятие', icon: 'building' },
  adm: { label: 'Допуск', icon: 'shieldCheck' },
  team: { label: 'Команда', icon: 'users' },
  rep: { label: 'Репутация', icon: 'starOutline' },
  appeals: { label: 'Обращения', icon: 'chat' },
}

export const profileTabLabel = (tab: MpkProfileTab): string => TAB_META[tab].label

export function ProfileTabs({ active, onChange }: { active: MpkProfileTab; onChange: (tab: MpkProfileTab) => void }) {
  return (
    <div className="mpkc-tabs" role="tablist" aria-label="Подразделы профиля">
      {MPK_PROFILE_TABS.map((id) => {
        const on = id === active
        return (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={on}
            className={`mpkc-tab${on ? ' on' : ''}`}
            onClick={() => onChange(id)}
          >
            <PhIcon name={TAB_META[id].icon} size={14} />
            <span>{TAB_META[id].label}</span>
          </button>
        )
      })}
    </div>
  )
}

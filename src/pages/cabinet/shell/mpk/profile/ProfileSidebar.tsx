// AgOS · Slice10 · SCR-P0 — сайдбар консоли профиля МПК (272px, §2).
//
// Состав — решение владельца D-MPK-NAV-01 (вариант Б): показываем ВСЕ шесть пунктов
// прототипа. Пять нереализованных на десктопе ведут на честное «Раздел в разработке»
// (FR-013), а не в никуда и не в мобильную оболочку. Полный сайдбар сразу показывает
// карту продукта, добавление разделов позже не потребует переделки навигации (P7).
//
// Иконки — только PhIcon (Phosphor): D-UI-FARMER-RULES-01 запрещает вторую библиотеку
// в зоне кабинета, поэтому DS-имена прототипа отображены на набор PhIcon (§0.4, §13.1).

import { PhIcon, type PhIconName } from '../../components/icons/PhIcon'
import { TuranStar } from '../../components/icons/TuranStar'

export interface SidebarNavItem {
  id: string
  icon: PhIconName
  label: string
}

// §2 · таблица пунктов. `profile` — единственный построенный на десктопе (этот слайс).
export const SIDEBAR_PRIMARY: SidebarNavItem[] = [
  { id: 'dashboard', icon: 'dashboard', label: 'Главная' },
  { id: 'requests', icon: 'fileText', label: 'Мои заявки' },
  { id: 'offers', icon: 'mail', label: 'Входящие офферы' },
  { id: 'market', icon: 'barChart', label: 'Маркет-борд' },
]

export const SIDEBAR_SECONDARY: SidebarNavItem[] = [
  { id: 'profile', icon: 'building', label: 'Профиль МПК' },
  { id: 'docs', icon: 'folder', label: 'Документы сделок' },
]

interface ProfileSidebarProps {
  orgName: string
  farmName: string
  userName: string
  monogram: string
  theme: 'dark' | 'light'
  /** id пункта, под которым показана подсказка «Раздел в разработке»; null — нет подсказки.
   *  Подсказка принадлежит ПУНКТУ, а не экрану: контент и URL она не меняет (M-003). */
  soonHint: string | null
  onSelect: (item: SidebarNavItem) => void
  onThemeToggle: () => void
  onBackToMpk: () => void
}

export function ProfileSidebar({
  orgName, farmName, userName, monogram,
  theme, soonHint, onSelect, onThemeToggle, onBackToMpk,
}: ProfileSidebarProps) {
  const renderItem = (item: SidebarNavItem) => {
    // Построен на десктопе только профиль — он и есть активный раздел консоли. Остальные
    // пять пунктов кликабельны и честно сообщают о себе, но никуда не ведут (FR-009/FR-013).
    const built = item.id === 'profile'
    const hinted = item.id === soonHint
    return (
      <div key={item.id}>
        <button
          type="button"
          className={`mpkc-item${built ? ' on' : ''}${built ? '' : ' soon'}`}
          aria-current={built ? 'page' : undefined}
          aria-expanded={built ? undefined : hinted}
          onClick={() => onSelect(item)}
        >
          <PhIcon name={item.icon} size={16} />
          <span className="mpkc-item-label">{item.label}</span>
        </button>
        {hinted && !built && (
          <div className="mpkc-soon" role="status">
            Раздел в разработке
          </div>
        )}
      </div>
    )
  }

  return (
    <aside className="mpkc-side" aria-label="Разделы кабинета МПК">
      <div className="mpkc-side-head">
        <div className="mpkc-org">
          <TuranStar size={26} />
          <div className="mpkc-org-txt">
            <div className="mpkc-org-name">{orgName}</div>
            <div className="mpkc-org-sub">{farmName}</div>
          </div>
        </div>
      </div>

      <nav className="mpkc-nav">
        {SIDEBAR_PRIMARY.map(renderItem)}
        <div className="mpkc-div" />
        {SIDEBAR_SECONDARY.map(renderItem)}
      </nav>

      <div className="mpkc-side-foot">
        {/* Единственный рабочий выход из консоли, пока остальные разделы не построены (§2). */}
        <button type="button" className="mpkc-back" onClick={onBackToMpk}>
          <PhIcon name="chevronLeft" size={14} />
          <span>Вернуться в закупки</span>
        </button>

        <div className="mpkc-user">
          <span className="mpkc-mark" aria-hidden="true">{monogram}</span>
          <div className="mpkc-user-txt">
            {/* Должность сотрудника не показываем: её источник — RBAC раздела «Команда»
                (MP-3.5), которого ещё нет. Пустая ветка «на потом» здесь не заводится. */}
            <div className="mpkc-user-name">{userName}</div>
          </div>
          <button
            type="button"
            className="mpkc-theme"
            onClick={onThemeToggle}
            aria-label={theme === 'dark' ? 'Светлая тема' : 'Тёмная тема'}
            title={theme === 'dark' ? 'Светлая тема' : 'Тёмная тема'}
          >
            <PhIcon name={theme === 'dark' ? 'sun' : 'moon'} size={14} />
          </button>
        </div>
      </div>
    </aside>
  )
}

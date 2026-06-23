import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'
import { useShell } from './ShellContext'
import {
  LayoutDashboard,
  Leaf,
  Fence,
  Stethoscope,
  Wheat,
  Users,
  BookOpen,
  Calculator,
  ClipboardList,
  ShoppingCart,
  Package,
  DollarSign,
  UserCog,
  Building2,
  Settings,
  Syringe,
  Shield,
  FileText,
  Activity,
  BarChart3,
  PanelLeftClose,
  Search,
  Sun,
  Moon,
  LogOut,
  Briefcase,
  User,
  Library,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

/* ---- Turan Logo Icon ---- */
function TuranIcon({ size = 24 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 130 130" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M20.5996 33.3L44.8296 57.53C45.8396 58.54 47.4696 58.54 48.4696 57.53L54.3896 51.61C67.4696 38.53 74.8196 20.79 74.8196 2.3V0H56.4396V43.15L33.5996 20.31L20.5996 33.31V33.3Z" fill="#F7931E"/>
      <path d="M109.13 96.4499L84.9002 72.2199C83.8902 71.2099 82.2602 71.2099 81.2602 72.2199L75.3402 78.1399C62.2602 91.2199 54.9102 108.96 54.9102 127.45V129.74H73.2902V86.5899L96.1301 109.43L109.13 96.4299V96.4499Z" fill="#F7931E"/>
      <path d="M96.4397 20.6099L72.2096 44.8399C71.1996 45.8499 71.1996 47.4799 72.2096 48.4799L78.1296 54.3999C91.2096 67.4799 108.95 74.8299 127.44 74.8299H129.73V56.4499H86.5797L109.42 33.6099L96.4196 20.6099H96.4397Z" fill="#F7931E"/>
      <path d="M33.29 109.14L57.52 84.9099C58.53 83.8999 58.53 82.2699 57.52 81.2699L51.6 75.3499C38.52 62.2699 20.78 54.9199 2.29 54.9199H0V73.2999H43.15L20.31 96.1399L33.31 109.14H33.29Z" fill="#F7931E"/>
    </svg>
  )
}

/* ---- Nav types ---- */
interface NavItem {
  id: string
  icon: LucideIcon
  label: string
  route: string
}

interface NavGroup {
  label?: string
  items: NavItem[]
}

/* ---- Grouped nav definitions per role ---- */

const FARMER_GROUPS: NavGroup[] = [
  {
    label: 'Основное',
    items: [
      { id: 'dashboard', icon: LayoutDashboard, label: 'Главная', route: '/cabinet-legacy' },
      { id: 'farm', icon: Leaf, label: 'Ферма', route: '/cabinet-legacy/farm' },
    ],
  },
  {
    label: 'Поголовье',
    items: [
      { id: 'herd', icon: Fence, label: 'Стадо', route: '/cabinet-legacy/herd' },
      { id: 'vet', icon: Stethoscope, label: 'Ветеринария', route: '/cabinet-legacy/vet' },
      { id: 'feed', icon: Wheat, label: 'Корма', route: '/cabinet-legacy/feed' },
      { id: 'ration', icon: Calculator, label: 'Рацион', route: '/cabinet-legacy/ration' },
    ],
  },
  {
    label: 'Бизнес',
    items: [
      { id: 'plan', icon: ClipboardList, label: 'Планирование', route: '/cabinet-legacy/plan' },
      { id: 'market', icon: ShoppingCart, label: 'Рынок', route: '/cabinet-legacy/market' },
    ],
  },
]

const EXPERT_GROUPS: NavGroup[] = [
  {
    items: [
      { id: 'dashboard', icon: LayoutDashboard, label: 'Главная', route: '/admin' },
    ],
  },
  {
    label: 'Клиника',
    items: [
      { id: 'vet-queue', icon: Stethoscope, label: 'Вет. кейсы', route: '/admin/expert/queue' },
      { id: 'vaccination', icon: Syringe, label: 'Вакцинация', route: '/admin/expert/vaccination' },
      { id: 'epidemic', icon: Activity, label: 'Эпидемиология', route: '/admin/expert/epidemic' },
    ],
  },
  {
    label: 'Аналитика',
    items: [
      { id: 'expert-kpi', icon: BarChart3, label: 'Мои показатели', route: '/admin/expert/kpi' },
    ],
  },
]

const ADMIN_GROUPS: NavGroup[] = [
  {
    label: 'Участники',
    items: [
      { id: 'dashboard', icon: LayoutDashboard, label: 'Главная', route: '/admin' },
      { id: 'applications', icon: FileText, label: 'Заявки', route: '/admin/applications' },
      { id: 'users', icon: UserCog, label: 'Пользователи', route: '/admin/users' },
      { id: 'roles', icon: Users, label: 'Роли', route: '/admin/roles' },
      { id: 'orgs', icon: Building2, label: 'Организации', route: '/admin/orgs' },
    ],
  },
  {
    label: 'Клиника',
    items: [
      { id: 'vet-queue', icon: Stethoscope, label: 'Вет. кейсы', route: '/admin/expert/queue' },
      { id: 'vaccination', icon: Syringe, label: 'Вакцинация', route: '/admin/expert/vaccination' },
      { id: 'epidemic', icon: Activity, label: 'Эпидемиология', route: '/admin/expert/epidemic' },
      { id: 'expert-kpi', icon: BarChart3, label: 'KPI эксперта', route: '/admin/expert/kpi' },
      { id: 'restrictions', icon: Shield, label: 'Ограничения', route: '/admin/restrictions' },
    ],
  },
  {
    label: 'Платформа',
    items: [
      { id: 'knowledge', icon: BookOpen, label: 'База знаний', route: '/admin/knowledge' },
      { id: 'audit', icon: FileText, label: 'Аудит', route: '/admin/audit' },
      { id: 'pools', icon: Package, label: 'Пулы', route: '/admin/pools' },
      { id: 'pricing', icon: DollarSign, label: 'Цены', route: '/admin/pricing' },
      { id: 'settings', icon: Settings, label: 'Настройки', route: '/admin/settings' },
      { id: 'consulting', icon: Briefcase, label: 'Консалтинг', route: '/admin/consulting' },
    ],
  },
  {
    label: 'Справочники',
    items: [
      { id: 'directories', icon: Library, label: 'Справочники', route: '/admin/directories' },
    ],
  },
]

/* ---- Icon button helper ---- */
function IconBtn({
  onClick,
  title,
  ariaLabel,
  children,
}: {
  onClick: () => void
  title?: string
  ariaLabel?: string
  children: React.ReactNode
}) {
  const [focused, setFocused] = useState(false)
  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={ariaLabel || title}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      style={{
        width: 28,
        height: 28,
        borderRadius: 6,
        display: 'grid',
        placeItems: 'center',
        background: 'none',
        border: 'none',
        outline: 'none',
        color: 'var(--fg3)',
        cursor: 'pointer',
        transition: 'background-color 150ms cubic-bezier(0.16,1,0.3,1), color 150ms cubic-bezier(0.16,1,0.3,1), box-shadow 150ms cubic-bezier(0.16,1,0.3,1)',
        boxShadow: focused ? '0 0 0 2px var(--bd-h)' : 'none',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.background = 'var(--bg-m)'
        e.currentTarget.style.color = 'var(--fg)'
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.background = 'none'
        e.currentTarget.style.color = 'var(--fg3)'
      }}
    >
      {children}
    </button>
  )
}

export function Sidebar() {
  const { sidebar, cycleSidebar, theme, setTheme } = useShell()
  const { userContext, signOut, role } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()

  const isExpanded = sidebar === 'expanded'
  const isCollapsed = sidebar === 'collapsed'

  const isAdminSection = location.pathname.startsWith('/admin')
  const { isAdmin: isAdminRole } = useAuth()
  const navGroups = isAdminSection
    ? (isAdminRole ? ADMIN_GROUPS : EXPERT_GROUPS)
    : FARMER_GROUPS

  const getIsActive = (item: NavItem) => {
    if (item.route === '/cabinet-legacy' || item.route === '/admin') {
      return location.pathname === item.route
    }
    return location.pathname.startsWith(item.route)
  }

  const fullName = userContext?.full_name || ''
  const initials = fullName
    ? fullName
        .split(' ')
        .map((w) => w[0])
        .join('')
        .toUpperCase()
        .slice(0, 2)
    : (role || 'U').slice(0, 2).toUpperCase()

  const displayName = fullName || userContext?.phone || 'User'
  const displayRole = isAdminSection ? 'Admin' : (role || 'farmer')

  /* ---- Footer dropdown ---- */
  const footerRef = useRef<HTMLDivElement>(null)
  const [footerOpen, setFooterOpen] = useState(false)

  useEffect(() => {
    if (!footerOpen) return
    function onPointerDown(e: PointerEvent) {
      if (footerRef.current && !footerRef.current.contains(e.target as Node)) {
        setFooterOpen(false)
      }
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') setFooterOpen(false)
    }
    document.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [footerOpen])

  const footerActions = [
    {
      label: 'Профиль',
      icon: User,
      destructive: false,
      action: () => {
        navigate(isAdminSection ? '/cabinet' : '/cabinet-legacy/farm')
        setFooterOpen(false)
      },
    },
    {
      label: 'Настройки',
      icon: Settings,
      destructive: false,
      action: () => {
        if (isAdminRole) navigate('/admin/settings')
        setFooterOpen(false)
      },
    },
    {
      label: 'Выйти',
      icon: LogOut,
      destructive: true,
      action: () => {
        signOut()
        setFooterOpen(false)
      },
    },
  ]

  if (sidebar === 'hidden') {
    return <div style={{ gridRow: '1 / -1' }} />
  }

  return (
    <aside
      style={{
        gridRow: '1 / -1',
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--bg-s)',
        borderRight: '1px solid var(--bd)',
        overflow: 'hidden',
      }}
    >
      {/* Workspace header */}
      <div
        style={{
          padding: isExpanded ? '12px 10px 8px' : '12px 8px 8px',
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          justifyContent: isCollapsed ? 'center' : 'flex-start',
        }}
      >
        <TuranIcon size={24} />
        {isExpanded && (
          <>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div
                style={{
                  fontSize: 13,
                  fontWeight: 600,
                  letterSpacing: '-0.01em',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                AgOS
              </div>
              <div style={{ fontSize: 11, color: 'var(--fg3)', marginTop: -1 }}>
                TURAN
              </div>
            </div>
            <IconBtn onClick={cycleSidebar} title="Collapse Cmd+B" ariaLabel="Collapse sidebar">
              <PanelLeftClose size={15} />
            </IconBtn>
          </>
        )}
      </div>

      {/* Search trigger */}
      {isExpanded && (
        <div style={{ padding: '8px 10px 4px' }}>
          <button
            style={{
              width: '100%',
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '6px 10px',
              borderRadius: 6,
              background: 'var(--bg-c)',
              border: '1px solid var(--bd)',
              outline: 'none',
              color: 'var(--fg3)',
              fontSize: 13,
              cursor: 'pointer',
              fontFamily: 'inherit',
              transition: 'background-color 150ms cubic-bezier(0.16,1,0.3,1), color 150ms cubic-bezier(0.16,1,0.3,1), box-shadow 150ms cubic-bezier(0.16,1,0.3,1)',
            }}
            onFocus={(e) => { e.currentTarget.style.boxShadow = '0 0 0 2px var(--bd-h)' }}
            onBlur={(e) => { e.currentTarget.style.boxShadow = 'none' }}
          >
            <Search size={13} strokeWidth={2} />
            <span style={{ flex: 1, textAlign: 'left' }}>Search...</span>
            <span
              style={{
                fontSize: 11,
                padding: '2px 6px',
                borderRadius: 4,
                background: 'var(--bg)',
                border: '1px solid var(--bd)',
                color: 'var(--fg3)',
                fontFamily: 'inherit',
              }}
            >
              Cmd+K
            </span>
          </button>
        </div>
      )}
      {isCollapsed && (
        <div style={{ padding: '8px 0 4px', display: 'flex', justifyContent: 'center' }}>
          <IconBtn onClick={() => {}} title="Search Cmd+K">
            <Search size={15} />
          </IconBtn>
        </div>
      )}

      {/* Navigation — grouped */}
      <nav
        style={{
          padding: isExpanded ? '8px' : '8px 4px',
          flex: 1,
          overflowY: 'auto',
        }}
      >
        {navGroups.map((group, gi) => (
          <div key={gi}>
            {/* Group label (expanded only) */}
            {group.label && isExpanded && (
              <div
                style={{
                  fontSize: 11,
                  fontWeight: 600,
                  color: 'var(--fg3)',
                  letterSpacing: '0.04em',
                  textTransform: 'uppercase',
                  padding: gi === 0 ? '8px 10px 6px' : '16px 10px 6px',
                  userSelect: 'none',
                }}
              >
                {group.label}
              </div>
            )}

            {/* Nav items */}
            {group.items.map((item) => {
              const Icon = item.icon
              const isActive = getIsActive(item)

              return (
                <button
                  key={item.id}
                  onClick={() => navigate(item.route)}
                  title={isCollapsed ? item.label : undefined}
                  aria-current={isActive ? 'page' : undefined}
                  style={{
                    width: '100%',
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                    borderRadius: 6,
                    background: isActive ? 'var(--bg-m)' : 'transparent',
                    border: 'none',
                    outline: 'none',
                    color: isActive ? 'var(--fg)' : 'var(--fg2)',
                    fontSize: 13,
                    fontWeight: isActive ? 500 : 400,
                    cursor: 'pointer',
                    fontFamily: 'inherit',
                    transition: 'background-color 150ms cubic-bezier(0.16,1,0.3,1), color 150ms cubic-bezier(0.16,1,0.3,1), box-shadow 150ms cubic-bezier(0.16,1,0.3,1)',
                    marginBottom: 2,
                    justifyContent: isCollapsed ? 'center' : 'flex-start',
                    padding: isCollapsed ? '6px' : '6px 10px',
                  }}
                  onMouseEnter={(e) => {
                    if (!isActive) {
                      e.currentTarget.style.background = 'var(--bg-m)'
                      e.currentTarget.style.color = 'var(--fg)'
                    }
                  }}
                  onMouseLeave={(e) => {
                    if (!isActive) {
                      e.currentTarget.style.background = 'transparent'
                      e.currentTarget.style.color = 'var(--fg2)'
                    }
                  }}
                  onFocus={(e) => { e.currentTarget.style.boxShadow = '0 0 0 2px var(--bd-h)' }}
                  onBlur={(e) => { e.currentTarget.style.boxShadow = 'none' }}
                >
                  <Icon
                    size={16}
                    strokeWidth={1.5}
                    style={{ color: isActive ? 'var(--fg)' : 'var(--fg3)' }}
                  />
                  {isExpanded && (
                    <span style={{ flex: 1, textAlign: 'left' }}>{item.label}</span>
                  )}
                </button>
              )
            })}
          </div>
        ))}
      </nav>

      {/* User footer */}
      <div
        style={{
          padding: '8px',
          borderTop: '1px solid var(--bd)',
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          justifyContent: isCollapsed ? 'center' : 'space-between',
        }}
      >
        {/* Clickable user info block */}
        <div
          ref={footerRef}
          role="button"
          tabIndex={0}
          aria-label="User menu"
          onClick={() => setFooterOpen((v) => !v)}
          onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') setFooterOpen((v) => !v) }}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            flex: isExpanded ? 1 : 'none',
            minWidth: 0,
            padding: '4px 6px',
            borderRadius: 6,
            cursor: 'pointer',
            transition: 'background-color 150ms cubic-bezier(0.16,1,0.3,1)',
            background: footerOpen ? 'var(--bg-m)' : 'none',
          }}
          onMouseEnter={(e) => {
            if (!footerOpen) e.currentTarget.style.background = 'var(--bg-m)'
          }}
          onMouseLeave={(e) => {
            if (!footerOpen) e.currentTarget.style.background = 'none'
          }}
        >
          <div
            style={{
              width: 28,
              height: 28,
              borderRadius: 9999,
              background: 'var(--cta)',
              color: 'var(--cta-fg)',
              display: 'grid',
              placeItems: 'center',
              fontSize: 11,
              fontWeight: 600,
              flexShrink: 0,
            }}
          >
            {initials}
          </div>
          {isExpanded && (
            <div style={{ flex: 1, minWidth: 0 }}>
              <div
                style={{
                  fontSize: 13,
                  fontWeight: 500,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {displayName}
              </div>
              <div style={{ fontSize: 11, color: 'var(--fg3)', marginTop: -1 }}>
                {displayRole}
              </div>
            </div>
          )}
        </div>

        {/* Theme toggle — preserved outside the dropdown trigger */}
        {isExpanded && (
          <IconBtn
            onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
            title="Toggle theme"
            ariaLabel="Toggle theme"
          >
            {theme === 'dark' ? <Sun size={14} /> : <Moon size={14} />}
          </IconBtn>
        )}
      </div>

      {/* Footer dropdown portal */}
      {footerOpen && footerRef.current && createPortal(
        (() => {
          const rect = footerRef.current!.getBoundingClientRect()
          return (
            <div
              style={{
                position: 'fixed',
                bottom: window.innerHeight - rect.top + 4,
                left: rect.left,
                minWidth: 168,
                background: 'var(--bg-c)',
                border: '1px solid var(--bd)',
                borderRadius: 8,
                boxShadow: 'var(--sh-md)',
                overflow: 'hidden',
                zIndex: 100,
              }}
            >
              {footerActions.map((action) => {
                const Icon = action.icon
                return (
                  <button
                    key={action.label}
                    onClick={action.action}
                    style={{
                      width: '100%',
                      display: 'flex',
                      alignItems: 'center',
                      gap: 10,
                      padding: '8px 12px',
                      background: 'none',
                      border: 'none',
                      outline: 'none',
                      color: action.destructive ? 'var(--red)' : 'var(--fg2)',
                      fontSize: 13,
                      fontWeight: 400,
                      cursor: 'pointer',
                      fontFamily: 'inherit',
                      textAlign: 'left',
                      transition: 'background-color 150ms cubic-bezier(0.16,1,0.3,1), color 150ms cubic-bezier(0.16,1,0.3,1), box-shadow 150ms cubic-bezier(0.16,1,0.3,1)',
                    }}
                    onMouseEnter={(e) => {
                      e.currentTarget.style.background = 'var(--bg-m)'
                      if (!action.destructive) e.currentTarget.style.color = 'var(--fg)'
                    }}
                    onMouseLeave={(e) => {
                      e.currentTarget.style.background = 'none'
                      e.currentTarget.style.color = action.destructive ? 'var(--red)' : 'var(--fg2)'
                    }}
                    onFocus={(e) => { e.currentTarget.style.boxShadow = '0 0 0 2px var(--bd-h)' }}
                    onBlur={(e) => { e.currentTarget.style.boxShadow = 'none' }}
                  >
                    <Icon size={14} strokeWidth={1.5} />
                    {action.label}
                  </button>
                )
              })}
            </div>
          )
        })(),
        document.body
      )}
    </aside>
  )
}

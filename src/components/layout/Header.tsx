import { useEffect, useRef, useState } from 'react'
import { useLocation, NavLink, useMatch } from 'react-router-dom'
import { PanelLeft } from 'lucide-react'
import { useShell } from './ShellContext'
import { useTopbarConfig, type TopbarTab } from './TopbarContext'

/**
 * Route-to-title mapping.
 * Extend as new screens are added.
 */
const ROUTE_TITLES: Record<string, string> = {
  '/cabinet-legacy': 'Dashboard',
  '/cabinet-legacy/farm': 'Farm Profile',
  '/cabinet-legacy/herd': 'Herd',
  '/cabinet-legacy/vet/new': 'Report Sick Animal',
  '/cabinet-legacy/feed': 'Feed',
  '/admin': 'Admin Dashboard',
  '/admin/applications': 'Заявки',
  '/admin/users': 'Users',
  '/admin/knowledge': 'Knowledge',
  '/admin/consulting': 'Консалтинг',
}

function getPageTitle(pathname: string): string {
  if (ROUTE_TITLES[pathname]) return ROUTE_TITLES[pathname]

  if (pathname.startsWith('/cabinet-legacy/vet/') && pathname !== '/cabinet-legacy/vet/new') {
    return 'Vet Case'
  }
  if (pathname.startsWith('/admin/applications/level/')) {
    return 'Смена уровня — решение'
  }

  const segments = pathname.split('/').filter(Boolean)
  const last = segments[segments.length - 1] || 'Dashboard'
  return last.charAt(0).toUpperCase() + last.slice(1)
}

/* ---- Single tab item with hover state and aria attributes ---- */
function HeaderTab({ tab }: { tab: TopbarTab }) {
  const match = useMatch({ path: tab.path, end: true })
  const isActive = !!match
  const [hovered, setHovered] = useState(false)

  return (
    <NavLink
      to={tab.path}
      end
      role="tab"
      aria-selected={isActive}
      style={{
        display: 'flex',
        alignItems: 'center',
        padding: '0 10px',
        fontSize: 13,
        fontWeight: 500,
        textDecoration: 'none',
        whiteSpace: 'nowrap',
        cursor: 'pointer',
        color: hovered || isActive ? 'var(--fg)' : 'var(--fg2)',
        borderBottom: `2px solid ${isActive ? 'var(--brand)' : 'transparent'}`,
        background: hovered ? 'var(--bg-m)' : 'none',
        transition: 'color 80ms, background 80ms, border-color 80ms',
      }}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
    >
      {tab.label}
    </NavLink>
  )
}

export function Header() {
  const { sidebar, cycleSidebar, panelOpen } = useShell()
  const location = useLocation()
  const { config } = useTopbarConfig()

  const title = config.title ?? getPageTitle(location.pathname)
  const tabs = config.tabs
  const actions = config.actions

  /* ---- Overflow detection for tab fade mask ---- */
  const tabsNavRef = useRef<HTMLElement>(null)
  const [hasOverflow, setHasOverflow] = useState(false)

  useEffect(() => {
    const el = tabsNavRef.current
    if (!el) return
    const check = () => setHasOverflow(el.scrollWidth > el.clientWidth)
    check()
    const ro = new ResizeObserver(check)
    ro.observe(el)
    el.addEventListener('scroll', check)
    return () => {
      ro.disconnect()
      el.removeEventListener('scroll', check)
    }
  }, [tabs])

  if (config.headerContent) {
    return (
      <header
        style={{
          gridColumn: panelOpen ? '2 / 3' : '2 / -1',
          borderBottom: '1px solid var(--bd)',
          background: 'var(--bg)',
        }}
      >
        {config.headerContent}
      </header>
    )
  }

  return (
    <header
      style={{
        gridColumn: panelOpen ? '2 / 3' : '2 / -1',
        display: 'flex',
        alignItems: 'stretch',
        borderBottom: '1px solid var(--bd)',
        background: 'var(--bg)',
        height: 44,
      }}
    >
      {/* Left: sidebar toggle (when hidden) + page title */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          paddingLeft: 28,
          flexShrink: 0,
        }}
      >
        {sidebar === 'hidden' && (
          <button
            onClick={cycleSidebar}
            title="Show sidebar"
            style={{
              width: 28,
              height: 28,
              borderRadius: 6,
              display: 'grid',
              placeItems: 'center',
              background: 'none',
              border: 'none',
              color: 'var(--fg3)',
              cursor: 'pointer',
              transition: 'all 80ms',
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
            <PanelLeft size={15} />
          </button>
        )}
        {config.titleIcon && (
          <div style={{ display: 'flex', alignItems: 'center', color: 'var(--fg3)', flexShrink: 0 }}>
            {config.titleIcon}
          </div>
        )}
        {config.titleLoading
          ? <div className="sk" style={{ width: 120, height: 13, borderRadius: 5 }} />
          : <h1 style={{ fontSize: 14, fontWeight: 600, margin: 0, whiteSpace: 'nowrap' }}>{title}</h1>
        }
      </div>

      {/* Center: tabs (when configured) */}
      {tabs && tabs.length > 0 && (
        <nav
          ref={tabsNavRef as React.RefObject<HTMLElement>}
          role="tablist"
          className="tabs-scroll"
          style={{
            display: 'flex',
            flex: 1,
            paddingLeft: 12,
            overflowX: 'auto',
            scrollbarWidth: 'none',
            WebkitMaskImage: hasOverflow
              ? 'linear-gradient(to right, black calc(100% - 40px), transparent 100%)'
              : undefined,
            maskImage: hasOverflow
              ? 'linear-gradient(to right, black calc(100% - 40px), transparent 100%)'
              : undefined,
          } as React.CSSProperties}
        >
          {tabs.map((tab) => (
            <HeaderTab key={tab.path} tab={tab} />
          ))}
        </nav>
      )}

      {/* Right: action buttons */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          paddingRight: 28,
          paddingLeft: tabs && tabs.length > 0 ? 8 : 0,
          flexShrink: 0,
          marginLeft: tabs && tabs.length > 0 ? 0 : 'auto',
        }}
      >
        {actions}
      </div>
    </header>
  )
}

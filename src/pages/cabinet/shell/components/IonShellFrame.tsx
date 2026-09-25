// AgOS · S2 (ARS-148) · Ionic-каркас экрана фермера: IonPage + IonContent (+IonRefresher).
// Замена ShellFrame для фермерских экранов; ShellFrame сохраняется для МПК до S6.
// Контент экранов не меняется — .phone-scroll остаётся обёрткой с прежними отступами.

import type { ReactNode } from 'react'
import { IonPage, IonContent, IonRefresher, IonRefresherContent } from '@ionic/react'
import { OfflineBar } from './OfflineBar'

interface Props {
  label?: string
  children: ReactNode
  // P-4 (ARS-220): таб-бар переехал в единый постоянный IonTabs (CabinetApp), фрейм его
  // больше НЕ рендерит; скрытие бара на детальных экранах решается на уровне IonTabs (hideTabBar).
  // `noTabs` = «экран без меню»: без него рамка резервирует высоту бара под контентом и поднимает
  // док-футер над баром (.has-tabbar, ARS-822).
  noTabs?: boolean
  // Pull-to-refresh (spec §7): экраны с поллингом передают свой рефетч.
  onRefresh?: () => Promise<unknown>
  // Док-футер прототипа (ShellFrame footer/footBare) — sticky CTA над таб-баром.
  footer?: ReactNode
  footBare?: boolean
  // ARS-231 (Chatscope): экраны со СВОИМ скроллом (MessageList чата) отключают
  // скролл ion-content — иначе двойной скролл. Контент растягивается на всю высоту.
  noScroll?: boolean
}

export function IonShellFrame({ label, children, noTabs, onRefresh, footer, footBare, noScroll }: Props) {
  return (
    <IonPage data-screen-label={label || ''}>
      <OfflineBar />
      {/* C6 (ARS-220): постоянный таб-бар выведен из потока (position:absolute) и прячется
          transform-ом. Баровые экраны (4 таб-корня НЕ передают noTabs) резервируют высоту
          бара статично на весь срок жизни страницы — резерв не меняется при переходах, рывка нет. */}
      <IonContent scrollY={!noScroll} className={'agos-ion-content' + (noScroll ? ' ion-noscroll' : '') + (noTabs ? '' : ' has-tabbar')}>
        {onRefresh && (
          <IonRefresher
            slot="fixed"
            onIonRefresh={async (e) => {
              try { await onRefresh() } finally { e.detail.complete() }
            }}
          >
            <IonRefresherContent />
          </IonRefresher>
        )}
        <div className="phone-scroll">{children}</div>
      </IonContent>
      {/* ARS-822 FR-001/002: док баровой страницы поднимается над таб-баром — тот же статичный
          признак (нет noTabs), что у резерва контента выше. Правило — ionic.css .sh-foot.has-tabbar. */}
      {footer && <div className={'sh-foot' + (footBare ? ' bare' : '') + (noTabs ? '' : ' has-tabbar')}>{footer}</div>}
    </IonPage>
  )
}

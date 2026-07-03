// AgOS · S2 (ARS-148) · Ionic-каркас экрана фермера: IonPage + IonContent (+IonRefresher).
// Замена ShellFrame для фермерских экранов; ShellFrame сохраняется для МПК до S6.
// Контент экранов не меняется — .phone-scroll остаётся обёрткой с прежними отступами.

import type { ReactNode } from 'react'
import { IonPage, IonContent, IonRefresher, IonRefresherContent } from '@ionic/react'
import { OfflineBar } from './OfflineBar'
import { ShellTabBarIon } from './ShellTabBarIon'

interface Props {
  label?: string
  children: ReactNode
  noTabs?: boolean
  // Pull-to-refresh (spec §7): экраны с поллингом передают свой рефетч.
  onRefresh?: () => Promise<unknown>
}

export function IonShellFrame({ label, children, noTabs, onRefresh }: Props) {
  return (
    <IonPage data-screen-label={label || ''}>
      <OfflineBar />
      <IonContent className="agos-ion-content">
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
      {!noTabs && <ShellTabBarIon />}
    </IonPage>
  )
}

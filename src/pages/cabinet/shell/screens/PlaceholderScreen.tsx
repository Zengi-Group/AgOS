// AgOS · Экран-заглушка вкладок/разделов — пустое состояние в дизайне .mk-empty (EmptyState).
// Каркас (хедер/искра/таб-бар) уже работает; наполнение — следующие этапы.

import { IonShellFrame } from '../components/IonShellFrame'
import { ShellHead } from '../components/ShellHead'
import { HomeHead } from '../components/HomeHead'
import { TabHead } from '../components/TabHead'
import { EmptyState } from '../components/EmptyState'
import type { PhIconName } from '../components/icons/PhIcon'

interface Props {
  title: string
  sub?: string
  home?: boolean
  tab?: boolean            // вкладка (Ферма/Сообщения) → универсальный TabHead
  icon?: PhIconName        // иконка пустого состояния (под секцию)
  emptyTitle?: string      // заголовок empty-state (по умолчанию — coming-soon)
  emptySub?: string        // подпись empty-state
}

export function PlaceholderScreen({ title, sub, home, tab, icon = 'grid', emptyTitle, emptySub }: Props) {
  return (
    <IonShellFrame label={title}>
      {home ? <HomeHead /> : tab ? <TabHead title={title} /> : <ShellHead big title={title} sub={sub} />}
      <div className="mk">
        <EmptyState
          icon={icon}
          title={emptyTitle ?? 'Раздел в разработке'}
          sub={emptySub ?? 'Откроется на следующих этапах'}
        />
      </div>
    </IonShellFrame>
  )
}

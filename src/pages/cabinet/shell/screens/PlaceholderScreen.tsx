// AgOS · Этап 1 · Экран-заглушка для вкладок (наполнение — следующие этапы).
// Каркас (хедер/искра/таб-бар) уже работает; контент придёт позже.

import { IonShellFrame } from '../components/IonShellFrame'
import { ShellHead } from '../components/ShellHead'
import { HomeHead } from '../components/HomeHead'

interface Props {
  title: string
  sub?: string
  home?: boolean
}

export function PlaceholderScreen({ title, sub, home }: Props) {
  return (
    <IonShellFrame label={title}>
      {home ? <HomeHead /> : <ShellHead big title={title} sub={sub} />}
      <div className="ph-stub">
        <div className="ph-stub-t">{title}</div>
        <div className="ph-stub-s">Раздел откроется на следующих этапах</div>
      </div>
    </IonShellFrame>
  )
}

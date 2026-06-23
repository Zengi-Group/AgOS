// AgOS · Этап 1 · Хедер раздела: заголовок + искра. Без колокольчика, без аватара (shell/ui.jsx).

import { SparkBtn } from './SparkBtn'

export function ShellHead({ title, sub, big }: { title: string; sub?: string; big?: boolean }) {
  return (
    <div className={'sh-head' + (big ? ' big' : '')}>
      <div className="sh-head-l">
        <div className="sh-title">{title}</div>
        {sub && <div className="sh-sub">{sub}</div>}
      </div>
      <div className="sh-head-r">
        <SparkBtn />
      </div>
    </div>
  )
}

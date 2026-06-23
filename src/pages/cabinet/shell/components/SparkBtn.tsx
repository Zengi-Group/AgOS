// AgOS · Этап 1 · Искра в хедере — один вход в AI на экран (shell/ui.jsx).

import { useShell } from '../context'
import { SparkIc } from './icons/SparkIc'

export function SparkBtn({ ctx2, small }: { ctx2?: string; small?: boolean }) {
  const ctx = useShell()
  return (
    <button
      className={'hbtn spark' + (small ? ' small' : '')}
      title="Консультант TURAN"
      onClick={() => ctx.openAI(ctx2 || ctx.aiCtxDefault)}
    >
      <SparkIc size={small ? 14 : 16} />
    </button>
  )
}

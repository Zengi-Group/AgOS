// AgOS · ARS-231 · Аватар треда сообщений — icon-circle с фиксированной семантикой цвета
// (§16 прототипа): Консультант — звезда (accent) · Рынок — amber · Ферма — green · TURAN — «Т».

import { PhIcon } from './icons/PhIcon'
import { TuranStar } from './icons/TuranStar'
import { MSG_META, type ThreadId } from '../data/threads'

export function ThreadAv({ tid, size = 34 }: { tid: ThreadId; size?: number }) {
  const m = MSG_META[tid]
  return (
    <span className={'thr-av tone-' + m.tone}>
      {m.av === 'star' ? <TuranStar size={size} />
        : m.av === 'Т' ? <span className="thr-av-l">Т</span>
        : <PhIcon name={m.av} size={size} />}
    </span>
  )
}

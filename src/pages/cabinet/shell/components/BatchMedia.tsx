// AgOS · TSP · ARS-227 · Секция «Фото и видео» карточки партии.
// Плоские тайлы-чипы (R-18: граница + bg-c), PhIcon-only, тактильный отклик (R-28).
// Загрузка/удаление — только для владельца в статусах draft|published (editable);
// иначе — только просмотр галереи. Само-скрывается, когда показывать нечего.

import { useRef } from 'react'
import { PhIcon } from './icons/PhIcon'
import { TuranLoader } from '@/components/TuranLoader'
import { useBatchMedia, type BatchMediaItem } from '../hooks/useBatchMedia'

interface BatchMediaProps {
  batchId: string
  orgId: string | null | undefined
  editable: boolean               // статус draft|published + владелец
  toast?: (text: string) => void
}

function Tile({ item, editable, onRemove }: {
  item: BatchMediaItem; editable: boolean; onRemove: (i: BatchMediaItem) => void
}) {
  return (
    <div className="mk-media-tile">
      {item.url
        ? (item.type === 'video'
            ? <video className="mk-media-media" src={item.url} preload="metadata" muted playsInline />
            : <img className="mk-media-media" src={item.url} alt="" loading="lazy" />)
        : <div className="mk-media-ph"><PhIcon name={item.type === 'video' ? 'play' : 'image'} size={20} /></div>}
      {item.type === 'video' && (
        <span className="mk-media-badge" aria-hidden><PhIcon name="play" size={12} color="var(--bg-c)" /></span>
      )}
      {editable && (
        <button type="button" className="mk-media-del" aria-label="Удалить" onClick={() => onRemove(item)}>
          <PhIcon name="x" size={13} color="var(--bg-c)" />
        </button>
      )}
    </div>
  )
}

export function BatchMedia({ batchId, orgId, editable, toast }: BatchMediaProps) {
  const { items, loading, uploading, canUse, upload, remove } = useBatchMedia(batchId, orgId, toast)
  const inputRef = useRef<HTMLInputElement>(null)

  // Нет backend/локальная демо-партия — секции нет. Пусто и нельзя загрузить — тоже.
  if (!canUse) return null
  if (items.length === 0 && !editable && !loading) return null

  const onPick = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files ?? [])
    e.target.value = ''                       // разрешить повторный выбор того же файла
    for (const f of files) await upload(f)
  }

  return (
    <div className="blk">
      <div className="tier-h">
        <span className="tier-h-l">
          <span className="tier-label">ФОТО И ВИДЕО</span>
          {items.length > 0 && <span className="tier-count mk-mono">{items.length}</span>}
        </span>
      </div>

      <div className="mk-media">
        <div className="mk-media-grid">
          {items.map((it) => (
            <Tile key={it.id} item={it} editable={editable} onRemove={remove} />
          ))}
          {editable && (
            <button type="button" className="mk-media-add" onClick={() => inputRef.current?.click()} disabled={uploading}>
              {uploading
                ? <TuranLoader variant="spin" size={18} />
                : <><PhIcon name="plus" size={20} /><span className="mk-media-add-t">Добавить</span></>}
            </button>
          )}
        </div>

        {editable && items.length === 0 && !loading && (
          <div className="mk-media-hint">Фото и видео помогают покупателю оценить животных.</div>
        )}

        <input
          ref={inputRef}
          type="file"
          accept="image/*,video/*"
          multiple
          style={{ display: 'none' }}
          onChange={onPick}
        />
      </div>
    </div>
  )
}

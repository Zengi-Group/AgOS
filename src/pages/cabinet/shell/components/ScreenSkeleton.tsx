// AgOS · P-3 (ARS-219) · Единый скелет экранов фермера.
//
// Заменяет дженерик SkeletonBlocks (серые прямоугольники одной формы) силуэтами под
// РЕАЛЬНЫЙ layout каждого экрана — фермер видит «здесь будет баннер, здесь карточки»,
// а не абстрактные полосы. Переиспользует shimmer-примитив `.skel-blk`/`.skel-wrap`
// (cabinet.css) → единый визуальный язык загрузки на всех экранах (Home/Market/List/Batch).

export type SkelVariant = 'home' | 'market' | 'list' | 'batch'

function Blk({ h, w, r }: { h: number; w?: number | string; r?: number }) {
  return <div className="skel-blk" style={{ height: h, width: w, borderRadius: r }} />
}

/** Горизонтальный ряд skel-блоков (сервис-грид, табы). */
function Row({ children, gap = 8 }: { children: React.ReactNode; gap?: number }) {
  return <div style={{ display: 'flex', gap }}>{children}</div>
}

export function ScreenSkeleton({ variant }: { variant: SkelVariant }) {
  if (variant === 'home') {
    return (
      <div className="skel-wrap" aria-hidden>
        {/* баннер-карусель */}
        <Blk h={132} r={16} />
        {/* ряд из 4 сервис-плиток */}
        <Row>
          {Array.from({ length: 4 }).map((_, i) => <Blk key={i} h={64} w="25%" r={14} />)}
        </Row>
        {/* заголовок секции */}
        <Blk h={18} w="42%" r={6} />
        {/* тир-карточки */}
        <Blk h={96} r={14} />
        <Blk h={96} r={14} />
      </div>
    )
  }
  if (variant === 'market') {
    return (
      <div className="skel-wrap" aria-hidden>
        {/* строка табов-фильтров */}
        <Blk h={36} r={12} />
        {/* карточки партий */}
        <Blk h={104} r={14} />
        <Blk h={104} r={14} />
        <Blk h={104} r={14} />
      </div>
    )
  }
  if (variant === 'list') {
    return (
      <div className="skel-wrap" aria-hidden>
        <Blk h={36} r={12} />
        {/* заголовок группы */}
        <Blk h={16} w="50%" r={6} />
        <Blk h={88} r={14} />
        <Blk h={88} r={14} />
      </div>
    )
  }
  // batch
  return (
    <div className="skel-wrap" aria-hidden>
      {/* хедер карточки */}
      <Blk h={48} r={12} />
      {/* крупная карточка партии */}
      <Blk h={196} r={16} />
      <Row>
        <Blk h={64} w="50%" r={12} />
        <Blk h={64} w="50%" r={12} />
      </Row>
    </div>
  )
}

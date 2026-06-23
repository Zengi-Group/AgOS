// AgOS · Этап 2 · Скелетоны блоков при загрузке (shell/ui.jsx SkeletonBlocks).

export function SkeletonBlocks({ n }: { n?: number }) {
  return (
    <div className="skel-wrap">
      {Array.from({ length: n || 4 }).map((_, i) => (
        <div className="skel-blk" key={i} style={{ height: [54, 104, 88, 96, 70][i % 5] }} />
      ))}
    </div>
  )
}

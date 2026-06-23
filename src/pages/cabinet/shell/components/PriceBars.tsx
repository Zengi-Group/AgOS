// AgOS · Этап 2 · Мини-бары истории публикаций (shell/pricesheet.jsx PriceBars).

export function PriceBars({ bars }: { bars: number[] }) {
  const max = Math.max(...bars)
  const min = Math.min(...bars)
  const span = Math.max(max - min, 1)
  const last = bars.length - 1
  return (
    <div className="pbars" aria-hidden="true">
      {bars.map((v, i) => {
        const h = 8 + Math.round(((v - min) / span) * 22) // 8..30px
        const cls = i === last ? 'now' : i === last - 1 ? 'prev' : ''
        return <span key={i} className={'pbar ' + cls} style={{ height: h + 'px' }} />
      })}
    </div>
  )
}

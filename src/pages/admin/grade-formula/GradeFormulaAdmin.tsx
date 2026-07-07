/**
 * A-GRADE — Формула сорта МПК (admin).
 * /admin/grade-formula — просмотр и правка формулы, по которой упитанность фермерской
 * партии превращается в сорт МПК (Премиум / Высшая / Первая / Вторая) и защитную цену.
 * Backend: d02_tsp.sql Section 8b — rpc_get_grade_formula (read), rpc_admin_upsert_grade_formula (write).
 * P8: стандарт как данные, не код. Правка здесь = data update, без деплоя.
 */
import { useState } from 'react'
import { SlidersHorizontal, Pencil, Crown } from 'lucide-react'
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { toast } from 'sonner'

interface GradeFormulaRow {
  sort_key: string
  species: string
  name_ru: string
  fatness_match: string | null
  grade_code: string | null
  floor_price: number
  elite_only: boolean
  min_weight_kg: number | null
  elite_breeds: string[] | null
  sort_order: number
}

const SPECIES_LABEL: Record<string, string> = { КРС: 'КРС', МРС: 'МРС', krs: 'КРС', mrs: 'МРС' }

// Значения упитанности из мастера партии (WizStep). Совпадают с fatness_match в сиде.
const FATNESS_OPTIONS = ['Хорошая', 'Средняя', 'Ниже средней'] as const

export function GradeFormulaAdmin() {
  const { isAdmin, checking } = useAdminGuard()
  const [editItem, setEditItem] = useState<GradeFormulaRow | null>(null)

  const { data: rows, isLoading, refetch } = useRpc<GradeFormulaRow[]>('rpc_get_grade_formula', {})

  useSetTopbar({ title: 'Формула сорта', titleIcon: <SlidersHorizontal size={15} /> })

  if (checking) return <div className="page"><Skeleton className="h-48 w-full" /></div>
  if (!isAdmin) return null

  const COL = 'minmax(160px,1.6fr) 70px minmax(120px,1fr) 110px minmax(160px,1.4fr) 44px'

  return (
    <div className="page space-y-4">
      {/* Пояснение формулы */}
      <div className="rounded-[8px] border border-border/60 bg-muted/30 p-3 text-[12px] leading-relaxed" style={{ color: 'var(--fg2)' }}>
        <p className="mb-1"><b>Как работает формула.</b> Когда фермер публикует партию, система по <b>упитанности</b> определяет сорт для мясокомбината:</p>
        <ul className="ml-4 list-disc space-y-0.5">
          <li><b>Упитанность → сорт:</b> «{FATNESS_OPTIONS[0]}» → Высшая, «{FATNESS_OPTIONS[1]}» → Первая, «{FATNESS_OPTIONS[2]}» → Вторая.</li>
          <li><b>Премиум:</b> партия «Высшая» повышается до «Премиум», если порода элитная <i>и</i> вес ≥ порога (по умолчанию 450 кг).</li>
          <li><b>Защитная цена</b> — минимум ₸/кг, ниже которого ассоциация не рекомендует продавать. Ниже неё фермер публикует только с явным подтверждением.</li>
        </ul>
        <p className="mt-1.5 text-[11px]" style={{ color: 'var(--fg3)' }}>Правки применяются сразу — деплой не нужен (P8: стандарт как данные).</p>
      </div>

      {isLoading ? <Skeleton className="h-48 w-full" /> : (
        <div className="flex flex-col border border-border/60 rounded-[8px] overflow-hidden bg-background">
          {/* Header */}
          <div className="grid border-b border-border/60 bg-muted/40" style={{ gridTemplateColumns: COL }}>
            {[
              { label: 'Сорт' },
              { label: 'Вид' },
              { label: 'Упитанность' },
              { label: 'Защ. цена (₸/кг)', right: true },
              { label: 'Условие' },
              { label: '' },
            ].map((h, i) => (
              <div key={i}
                className={`h-[34px] px-3 flex items-center text-[11px] font-medium border-r border-border/60 last:border-r-0 ${h.right ? 'justify-end' : ''}`}
                style={{ color: 'var(--fg2)' }}>
                {h.label}
              </div>
            ))}
          </div>

          {/* Rows */}
          {(rows || []).length === 0 ? (
            <div className="h-[120px] flex items-center justify-center text-[13px]" style={{ color: 'var(--fg3)' }}>
              Формула не загружена. Проверьте таблицу livestock_grade_formula.
            </div>
          ) : (rows || []).map(r => (
            <div
              key={r.sort_key}
              onClick={() => setEditItem(r)}
              className="grid border-b border-border/60 cursor-pointer hover:bg-muted/40 transition-colors group last:border-b-0"
              style={{ gridTemplateColumns: COL }}
            >
              <div className="h-[40px] px-3 flex items-center gap-1.5 border-r border-border/60 min-w-0">
                {r.elite_only && <Crown className="h-3 w-3 shrink-0" style={{ color: '#c79a3a' }} />}
                <span className="text-[13px] font-medium truncate">{r.name_ru}</span>
              </div>
              <div className="h-[40px] px-3 flex items-center border-r border-border/60 text-[12px]">
                {SPECIES_LABEL[r.species] || r.species}
              </div>
              <div className="h-[40px] px-3 flex items-center border-r border-border/60 text-[12px]" style={{ color: 'var(--fg2)' }}>
                {r.fatness_match || (r.elite_only ? '— (повышение)' : '—')}
              </div>
              <div className="h-[40px] px-3 flex items-center justify-end border-r border-border/60 font-mono text-[13px] font-medium">
                {r.floor_price.toLocaleString('ru-RU')}
              </div>
              <div className="h-[40px] px-3 flex items-center border-r border-border/60 text-[11px] truncate" style={{ color: 'var(--fg3)' }}>
                {r.elite_only
                  ? `элитная порода + вес ≥ ${r.min_weight_kg ?? '—'} кг`
                  : r.grade_code ? `grade ${r.grade_code}` : '—'}
              </div>
              <div className="h-[40px] px-3 flex items-center justify-center text-muted-foreground group-hover:text-foreground">
                <Pencil className="h-3 w-3" />
              </div>
            </div>
          ))}
        </div>
      )}

      {editItem && (
        <FormulaDialog
          item={editItem}
          onClose={() => setEditItem(null)}
          onSaved={() => { refetch(); setEditItem(null) }}
        />
      )}
    </div>
  )
}

// ─── Edit dialog ─────────────────────────────────────────────────────────────

function FormulaDialog({
  item,
  onClose,
  onSaved,
}: {
  item: GradeFormulaRow
  onClose: () => void
  onSaved: () => void
}) {
  const [nameRu, setNameRu] = useState(item.name_ru)
  const [fatness, setFatness] = useState(item.fatness_match ?? '')
  const [floorPrice, setFloorPrice] = useState(String(item.floor_price))
  const [minWeight, setMinWeight] = useState(item.min_weight_kg != null ? String(item.min_weight_kg) : '')
  const [breeds, setBreeds] = useState((item.elite_breeds ?? []).join(', '))
  const [sortOrder, setSortOrder] = useState(String(item.sort_order))

  const upsert = useRpcMutation<Record<string, unknown>, { ok: boolean; error?: string }>(
    'rpc_admin_upsert_grade_formula',
    {
      onSuccess: (data) => {
        if (data?.ok) {
          toast.success('Формула сохранена')
          onSaved()
        } else {
          toast.error(data?.error === 'FLOOR_MUST_BE_POSITIVE' ? 'Защитная цена должна быть больше 0'
            : data?.error === 'FORBIDDEN' ? 'Нет прав администратора'
            : data?.error || 'Не удалось сохранить')
        }
      },
    },
  )

  const handleSave = () => {
    const price = Number(floorPrice)
    if (!price || price <= 0) { toast.error('Защитная цена должна быть больше 0'); return }
    const breedList = breeds.split(',').map(b => b.trim().toLowerCase()).filter(Boolean)
    upsert.mutate({
      p_sort_key:      item.sort_key,
      p_name_ru:       nameRu,
      p_fatness_match: item.elite_only ? null : (fatness || null),
      p_floor_price:   price,
      p_min_weight_kg: item.elite_only ? (minWeight === '' ? null : Number(minWeight)) : null,
      p_elite_breeds:  item.elite_only ? breedList : null,
      p_sort_order:    Number(sortOrder) || item.sort_order,
    })
  }

  return (
    <Dialog open onOpenChange={v => !v && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            {item.elite_only && <Crown className="h-4 w-4" style={{ color: '#c79a3a' }} />}
            Сорт «{item.name_ru}»
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-3 py-2">
          <div>
            <Label className="text-sm">Название сорта</Label>
            <Input value={nameRu} onChange={e => setNameRu(e.target.value)} placeholder="Высшая" />
          </div>

          {!item.elite_only && (
            <div>
              <Label className="text-sm">Упитанность → этот сорт</Label>
              <Select value={fatness} onValueChange={setFatness}>
                <SelectTrigger><SelectValue placeholder="—" /></SelectTrigger>
                <SelectContent>
                  {FATNESS_OPTIONS.map(o => <SelectItem key={o} value={o}>{o}</SelectItem>)}
                </SelectContent>
              </Select>
              <p className="text-[10px] text-muted-foreground mt-1">По какой упитанности партия относится к этому сорту.</p>
            </div>
          )}

          <div>
            <Label className="text-sm">Защитная цена (₸/кг)</Label>
            <Input type="number" value={floorPrice} onChange={e => setFloorPrice(e.target.value)}
              placeholder="1650" min={1} step="50" />
          </div>

          {item.elite_only && (
            <>
              <div>
                <Label className="text-sm">Минимальный вес для Премиум (кг)</Label>
                <Input type="number" value={minWeight} onChange={e => setMinWeight(e.target.value)}
                  placeholder="450" min={1} />
                <p className="text-[10px] text-muted-foreground mt-1">Партия «Высшая» повышается до «Премиум» при весе ≥ этого порога.</p>
              </div>
              <div>
                <Label className="text-sm">Элитные породы (через запятую)</Label>
                <Input value={breeds} onChange={e => setBreeds(e.target.value)}
                  placeholder="ангус, герефорд, вагю" />
                <p className="text-[10px] text-muted-foreground mt-1">Породы, дающие право на Премиум. Регистр не важен.</p>
              </div>
            </>
          )}

          <div>
            <Label className="text-sm">Порядок в списке</Label>
            <Input type="number" value={sortOrder} onChange={e => setSortOrder(e.target.value)} min={1} />
          </div>
        </div>

        <DialogFooter className="gap-2">
          <Button variant="outline" onClick={onClose}>Отмена</Button>
          <Button onClick={handleSave} disabled={upsert.isPending}>
            {upsert.isPending ? 'Сохранение…' : 'Сохранить'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

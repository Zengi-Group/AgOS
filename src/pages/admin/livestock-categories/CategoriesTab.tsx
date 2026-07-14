/**
 * A-CAT-01 — Категории скота (CRUD livestock_categories).
 * RPC: AR-1 rpc_admin_list_categories_with_stats · AC-1 upsert · AC-2 deactivate.
 */
import { useState, useEffect } from 'react'
import { Plus, Pencil, MoreHorizontal } from 'lucide-react'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { toast } from 'sonner'

interface CategoryRow {
  id: string
  code: string
  name_ru: string
  description_ru: string | null
  sort_order: number
  is_active: boolean
  active_rule_count: number
  sku_mapped_count: number
  has_minimum_price: boolean
  has_reference_price: boolean
}

// AR-4 rpc_admin_list_prices row (subset used for prefill of national row).
interface PriceRow {
  category_id: string
  region_id: string | null
  price_per_kg: number
}

const CODE_RE = /^[A-Z][A-Z0-9_]*$/

const ERR: Record<string, string> = {
  FORBIDDEN: 'Нет прав администратора',
  INVALID_INPUT: 'Проверьте заполнение полей',
  CATEGORY_NOT_FOUND: 'Категория не найдена',
  CATEGORY_IN_USE: 'Нельзя деактивировать: есть активный маппинг SKU или цены',
}

// TURAN стартовая гипотеза (Dok6 A-CAT §1.2) — подсказка, не seed.
const DEFAULT_SET = [
  { code: 'YOUNG_MEAT_ELITE',    name_ru: 'Молодняк мясной',            description_ru: 'Бычки/тёлки 6–24 мес мясного направления (elite + local)' },
  { code: 'YOUNG_CROSSBRED',     name_ru: 'Молодняк беспородный',        description_ru: 'Бычки/тёлки 6–24 мес crossbred' },
  { code: 'ADULT_BULL_MEAT',     name_ru: 'Взрослый бычок мясной',       description_ru: 'Бычки 24–48 мес мясного направления' },
  { code: 'ADULT_BULL_CROSSBRED', name_ru: 'Взрослый бычок беспородный', description_ru: 'Бычки 24–48 мес crossbred' },
  { code: 'COW_FATTENING',       name_ru: 'Корова на откорм/убой',       description_ru: 'Коровы 24–48 мес' },
  { code: 'COW_CULL_SENIOR',     name_ru: 'Корова на выбраковку',        description_ru: 'Коровы 48+ мес' },
]

export function CategoriesTab() {
  const [editItem, setEditItem] = useState<CategoryRow | null>(null)
  const [showCreate, setShowCreate] = useState(false)
  const [seeding, setSeeding] = useState(false)

  const { data: rows, isLoading, refetch } = useRpc<CategoryRow[]>('rpc_admin_list_categories_with_stats', {})

  const deactivate = useRpcMutation<{ p_category_id: string }, { ok: boolean; error?: string }>(
    'rpc_admin_deactivate_livestock_category',
    {
      onSuccess: (data) => {
        if (!data?.ok) { toast.error(ERR[data?.error ?? ''] ?? data?.error ?? 'Ошибка'); return }
        toast.success('Категория деактивирована')
        refetch()
      },
    },
  )

  async function seedDefaults() {
    setSeeding(true)
    try {
      for (const c of DEFAULT_SET) {
        await import('@/lib/supabase').then(({ supabase }) =>
          supabase.rpc('rpc_admin_upsert_livestock_category', {
            p_code: c.code, p_name_ru: c.name_ru, p_description_ru: c.description_ru, p_sort_order: 0,
          }),
        )
      }
      toast.success('Стандартный набор создан')
      refetch()
    } finally {
      setSeeding(false)
    }
  }

  const COL = '160px minmax(180px,2fr) minmax(160px,2fr) 60px 80px 90px 90px 80px 90px 44px'

  return (
    <div className="page space-y-4">
      <div className="flex items-center gap-2">
        <p className="text-[12px]" style={{ color: 'var(--fg3)' }}>
          Категории скота — защитный/индикативный стандарт TURAN. Фермер не выбирает категорию вручную:
          она выводится автоматически по правилам (вкладка «Формула»).
        </p>
        <Button size="sm" onClick={() => setShowCreate(true)} className="ml-auto h-7 px-3 text-[12px] font-medium">
          <Plus className="mr-1.5 h-3 w-3" /> Создать категорию
        </Button>
      </div>

      {isLoading ? <Skeleton className="h-48 w-full" /> : (rows || []).length === 0 ? (
        <div className="border border-border/60 rounded-[8px] p-6 text-center space-y-3 bg-muted/20">
          <p className="text-[13px]" style={{ color: 'var(--fg2)' }}>
            Категорий пока нет. Стандартный набор TURAN: Молодняк мясной, Молодняк беспородный,
            Взрослый бычок мясной, и т.д.
          </p>
          <Button size="sm" onClick={seedDefaults} disabled={seeding}>
            {seeding ? 'Создание…' : 'Создать набор по умолчанию (6)'}
          </Button>
        </div>
      ) : (
        <div className="flex flex-col border border-border/60 rounded-[8px] overflow-x-auto bg-background">
          <div className="grid border-b border-border/60 bg-muted/40 min-w-[900px]" style={{ gridTemplateColumns: COL }}>
            {['Код', 'Название (RU)', 'Описание', 'Sort', 'Активна', 'Правил', 'SKU', 'Floor', 'Reference', ''].map((h, i) => (
              <div key={i} className="h-[34px] px-3 flex items-center text-[11px] font-medium border-r border-border/60 last:border-r-0" style={{ color: 'var(--fg2)' }}>
                {h}
              </div>
            ))}
          </div>
          {(rows || []).map(r => (
            <div key={r.id} onClick={() => setEditItem(r)}
              className="grid border-b border-border/60 cursor-pointer hover:bg-muted/40 transition-colors group last:border-b-0 min-w-[900px]"
              style={{ gridTemplateColumns: COL }}>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 font-mono text-[11px] truncate">{r.code}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 text-[13px] font-medium truncate">{r.name_ru}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 text-[12px] truncate" style={{ color: 'var(--fg3)' }}>{r.description_ru || '—'}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 font-mono text-[12px]">{r.sort_order}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 text-[12px]">{r.is_active ? '✅' : '—'}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 font-mono text-[12px]">{Number(r.active_rule_count)}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 font-mono text-[12px]">{Number(r.sku_mapped_count)}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 text-[12px]">{r.has_minimum_price ? '✅' : '—'}</div>
              <div className="h-[38px] px-3 flex items-center border-r border-border/60 text-[12px]">{r.has_reference_price ? '✅' : '—'}</div>
              <div className="h-[38px] px-3 flex items-center justify-center text-muted-foreground group-hover:text-foreground">
                {r.is_active ? <Pencil className="h-3 w-3" /> : <MoreHorizontal className="h-3 w-3" />}
              </div>
            </div>
          ))}
        </div>
      )}

      {(showCreate || editItem) && (
        <CategoryDialog
          item={editItem}
          onDeactivate={editItem && editItem.is_active ? () => {
            if (confirm(`Деактивировать «${editItem.name_ru}»?`)) {
              deactivate.mutate({ p_category_id: editItem.id })
              setEditItem(null)
            }
          } : undefined}
          onClose={() => { setShowCreate(false); setEditItem(null) }}
          onSaved={() => { refetch(); setShowCreate(false); setEditItem(null) }}
        />
      )}
    </div>
  )
}

function CategoryDialog({
  item, onClose, onSaved, onDeactivate,
}: {
  item: CategoryRow | null
  onClose: () => void
  onSaved: () => void
  onDeactivate?: () => void
}) {
  const isEdit = !!item
  const [code, setCode] = useState(item?.code ?? '')
  const [nameRu, setNameRu] = useState(item?.name_ru ?? '')
  const [descRu, setDescRu] = useState(item?.description_ru ?? '')
  const [sortOrder, setSortOrder] = useState(String(item?.sort_order ?? 0))

  // ── Цены (только в режиме правки — нужен category_id) ─────────────────────
  // Упрощение карточки: национальная цена (region_id = null), valid_from = сегодня.
  // Регионы/история/версии — в полном экране A-CAT-04 (Phase 2).
  const today = new Date().toISOString().slice(0, 10)
  const { data: minRows } = useRpc<PriceRow[]>('rpc_admin_list_prices', { p_kind: 'minimum' }, { enabled: isEdit })
  const { data: refRows } = useRpc<PriceRow[]>('rpc_admin_list_prices', { p_kind: 'reference' }, { enabled: isEdit })
  const curMin = isEdit ? (minRows?.find(r => r.category_id === item!.id && r.region_id === null)?.price_per_kg ?? null) : null
  const curRef = isEdit ? (refRows?.find(r => r.category_id === item!.id && r.region_id === null)?.price_per_kg ?? null) : null

  const [minPrice, setMinPrice] = useState('')
  const [refPrice, setRefPrice] = useState('')
  const [primed, setPrimed] = useState(false)
  useEffect(() => {
    if (isEdit && !primed && minRows && refRows) {
      setMinPrice(curMin != null ? String(curMin) : '')
      setRefPrice(curRef != null ? String(curRef) : '')
      setPrimed(true)
    }
  }, [isEdit, primed, minRows, refRows, curMin, curRef])

  const [savingPrices, setSavingPrices] = useState(false)

  // Пишем цену только если поле заполнено и значение изменилось (AC-6/AC-7).
  // RPC возвращают jsonb {ok, error}; бизнес-ошибку (FORBIDDEN/INVALID_*) не бросают —
  // проверяем результат явно и превращаем в throw для общего catch.
  async function setPrice(fn: string, price: number) {
    const { data, error } = await supabase.rpc(fn, {
      p_category_id: item!.id, p_region_id: null, p_price_per_kg: price, p_valid_from: today,
    })
    if (error) throw error
    const res = data as { ok?: boolean; error?: string } | null
    if (!res?.ok) throw new Error(ERR[res?.error ?? ''] ?? res?.error ?? 'Ошибка сохранения цены')
  }

  async function persistPrices() {
    if (!isEdit) return
    const min = minPrice.trim()
    const ref = refPrice.trim()
    if (min !== '' && Number(min) !== curMin) await setPrice('rpc_admin_set_minimum_price', Number(min))
    if (ref !== '' && Number(ref) !== curRef) await setPrice('rpc_admin_set_reference_price', Number(ref))
  }

  const upsert = useRpcMutation<Record<string, unknown>, { ok: boolean; error?: string }>(
    'rpc_admin_upsert_livestock_category',
    {
      onSuccess: async (data) => {
        if (!data?.ok) { toast.error(ERR[data?.error ?? ''] ?? data?.error ?? 'Ошибка'); return }
        try {
          setSavingPrices(true)
          await persistPrices()
        } catch (e) {
          toast.error('Категория сохранена, но цену сохранить не удалось: ' + ((e as Error)?.message ?? ''))
          onSaved()
          return
        } finally {
          setSavingPrices(false)
        }
        toast.success('Категория сохранена')
        onSaved()
      },
    },
  )

  function handleSave() {
    if (!CODE_RE.test(code)) { toast.error('Код: заглавные латинские буквы, цифры, _ (напр. YOUNG_MEAT_ELITE)'); return }
    if (!nameRu.trim()) { toast.error('Укажите название'); return }
    if (minPrice.trim() !== '' && Number(minPrice) <= 0) { toast.error('Минимальная цена должна быть больше 0'); return }
    if (refPrice.trim() !== '' && Number(refPrice) <= 0) { toast.error('Рекомендованная цена должна быть больше 0'); return }
    upsert.mutate({
      p_code: code,
      p_name_ru: nameRu.trim(),
      p_description_ru: descRu.trim() || null,
      p_sort_order: Number(sortOrder) || 0,
    })
  }

  return (
    <Dialog open onOpenChange={v => !v && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>{isEdit ? 'Категория' : 'Новая категория'}</DialogTitle></DialogHeader>
        <div className="space-y-3 py-2">
          <div>
            <Label className="text-sm">Код</Label>
            <Input value={code} onChange={e => setCode(e.target.value.toUpperCase())} disabled={isEdit} placeholder="YOUNG_MEAT_ELITE" />
            {isEdit && <p className="text-[10px] text-muted-foreground mt-1">Код неизменяем. Для смены — создайте новую категорию.</p>}
          </div>
          <div>
            <Label className="text-sm">Название (RU)</Label>
            <Input value={nameRu} onChange={e => setNameRu(e.target.value)} placeholder="Молодняк мясной" />
          </div>
          <div>
            <Label className="text-sm">Описание (RU)</Label>
            <Input value={descRu} onChange={e => setDescRu(e.target.value)} placeholder="Бычки/тёлки 6–24 мес…" />
          </div>
          <div>
            <Label className="text-sm">Порядок сортировки</Label>
            <Input type="number" value={sortOrder} onChange={e => setSortOrder(e.target.value)} min={0} />
          </div>

          {isEdit && (
            <div className="space-y-3 pt-3 mt-1 border-t border-border/60">
              <p className="text-[11px] font-medium" style={{ color: 'var(--fg2)' }}>
                Цены (национальные, ₸/кг живого веса)
              </p>
              <div>
                <Label className="text-sm">Минимальная (защитная) цена</Label>
                <Input
                  type="number"
                  value={minPrice}
                  onChange={e => setMinPrice(e.target.value)}
                  placeholder="напр. 1500"
                  min={0}
                  step="50"
                />
                <p className="text-[10px] text-muted-foreground mt-1">
                  Защитный стандарт ассоциации. Пусто = не задавать.
                </p>
              </div>
              <div>
                <Label className="text-sm">Рекомендованная (индикативная) цена</Label>
                <Input
                  type="number"
                  value={refPrice}
                  onChange={e => setRefPrice(e.target.value)}
                  placeholder="напр. 1800"
                  min={0}
                  step="50"
                />
                <p className="text-[10px] text-muted-foreground mt-1 leading-snug">
                  Ст. 171 ПК РК: справочные цены являются индикативными рыночными ориентирами.
                  TURAN не устанавливает и не гарантирует цены сделок.
                </p>
              </div>
            </div>
          )}
        </div>
        <DialogFooter className="gap-2">
          {onDeactivate && (
            <Button variant="outline" onClick={onDeactivate} className="mr-auto text-destructive">Деактивировать</Button>
          )}
          <Button variant="outline" onClick={onClose}>Отмена</Button>
          <Button onClick={handleSave} disabled={upsert.isPending || savingPrices}>
            {upsert.isPending || savingPrices ? 'Сохранение…' : isEdit ? 'Сохранить' : 'Создать'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

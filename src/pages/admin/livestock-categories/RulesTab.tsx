/**
 * A-CAT-02 — Формула классификации (livestock_category_rules).
 * Показывает и редактирует правила, по которым животное относят к категории.
 * RPC: AR-1 (список категорий) · AR-2 rpc_admin_list_category_rules ·
 *      AC-3 rpc_admin_set_category_rule (stage, inactive) · AC-4 activate_rule_version.
 */
import { useState, useEffect, useMemo } from 'react'
import { Plus, CheckCircle2 } from 'lucide-react'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { toast } from 'sonner'

interface CategoryRow { id: string; code: string; name_ru: string; is_active: boolean }
interface Rule {
  id: string
  version: number
  breed_group: string | null
  sex: string | null
  age_min_months: number | null
  age_max_months: number | null
  weight_min_kg: number | null
  weight_max_kg: number | null
  bcs_min: number | null
  bcs_max: number | null
  priority: number
  is_active: boolean
}

const BREED = { elite_meat: 'Элитный мясной', local: 'Местный', crossbred: 'Беспородный' } as const
const SEX = { bull: 'Бычок', heifer: 'Тёлка', cow: 'Корова' } as const
const ANY = '__any__'

const ERR: Record<string, string> = {
  FORBIDDEN: 'Нет прав администратора',
  INVALID_INPUT: 'Проверьте заполнение полей',
  CATEGORY_NOT_FOUND: 'Категория не найдена',
  VERSION_NOT_FOUND: 'Версия не найдена',
}

function range(min: number | null, max: number | null, unit: string) {
  if (min == null && max == null) return 'любой'
  return `${min ?? '…'}–${max ?? '∞'} ${unit}`
}

export function RulesTab() {
  const [categoryId, setCategoryId] = useState<string>('')
  const [showAdd, setShowAdd] = useState(false)

  const { data: cats, isLoading: catsLoading } = useRpc<CategoryRow[]>('rpc_admin_list_categories_with_stats', {})
  const activeCats = useMemo(() => (cats || []).filter(c => c.is_active), [cats])

  useEffect(() => {
    const first = activeCats[0]
    if (!categoryId && first) setCategoryId(first.id)
  }, [activeCats, categoryId])

  const { data: rules, isLoading: rulesLoading, refetch } = useRpc<Rule[]>(
    'rpc_admin_list_category_rules',
    { p_category_id: categoryId },
    { enabled: !!categoryId },
  )

  const activate = useRpcMutation<{ p_category_id: string; p_version: number }, { ok: boolean; error?: string }>(
    'rpc_admin_activate_rule_version',
    {
      onSuccess: (data) => {
        if (!data?.ok) { toast.error(ERR[data?.error ?? ''] ?? data?.error ?? 'Ошибка'); return }
        toast.success(`Версия ${data && (data as any).version} активирована`)
        refetch()
      },
    },
  )

  // Group rules by version (desc). AR-2 already sorts version desc, priority desc.
  const versions = useMemo(() => {
    const map = new Map<number, Rule[]>()
    for (const r of rules || []) {
      if (!map.has(r.version)) map.set(r.version, [])
      map.get(r.version)!.push(r)
    }
    return Array.from(map.entries()).sort((a, b) => b[0] - a[0])
  }, [rules])

  const maxVersion = versions[0]?.[0] ?? 0
  const stagedVersions = versions.filter(([, rs]) => !rs.some(r => r.is_active)).map(([v]) => v)

  const COL = 'minmax(140px,1fr) 90px 110px 110px 100px 70px 90px'

  return (
    <div className="page space-y-4">
      {/* Формула — объяснение */}
      <div className="border border-border/60 rounded-[8px] p-3 bg-muted/20 text-[12px] leading-relaxed" style={{ color: 'var(--fg2)' }}>
        <b>Как определяется категория.</b> Система берёт параметры животного — порода, пол, возраст,
        вес, BCS — и проверяет правила <b>активной версии</b>. Правило подходит, если совпадают
        <b> все заданные</b> критерии (пустой критерий = любое значение). Если подходит несколько
        правил, побеждает то, у которого выше <b>priority</b>.
      </div>

      <div className="flex items-center gap-2">
        <div className="min-w-[240px]">
          <Select value={categoryId} onValueChange={setCategoryId} disabled={catsLoading || activeCats.length === 0}>
            <SelectTrigger className="h-8"><SelectValue placeholder="Выберите категорию" /></SelectTrigger>
            <SelectContent>
              {activeCats.map(c => <SelectItem key={c.id} value={c.id}>{c.name_ru}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
        <Button size="sm" onClick={() => setShowAdd(true)} disabled={!categoryId}
          className="ml-auto h-7 px-3 text-[12px] font-medium">
          <Plus className="mr-1.5 h-3 w-3" /> Добавить правило
        </Button>
      </div>

      {activeCats.length === 0 && !catsLoading && (
        <div className="text-[13px] p-4 text-center" style={{ color: 'var(--fg3)' }}>
          Нет активных категорий. Сначала создайте их на вкладке «Категории».
        </div>
      )}

      {rulesLoading ? <Skeleton className="h-40 w-full" /> : versions.length === 0 && categoryId ? (
        <div className="text-[13px] p-4 text-center" style={{ color: 'var(--fg3)' }}>
          Для этой категории ещё нет правил. Добавьте первое — оно попадёт в новую версию (черновик),
          затем активируйте версию.
        </div>
      ) : versions.map(([version, versionRules]) => {
        const isActiveVersion = versionRules.some(r => r.is_active)
        return (
          <div key={version} className="border border-border/60 rounded-[8px] overflow-hidden bg-background">
            <div className="flex items-center gap-2 px-3 h-[36px] bg-muted/40 border-b border-border/60">
              <span className="text-[12px] font-semibold">Версия {version}</span>
              {isActiveVersion ? (
                <span className="inline-flex items-center gap-1 text-[11px] text-emerald-600">
                  <CheckCircle2 className="h-3 w-3" /> Активна
                </span>
              ) : (
                <span className="text-[11px]" style={{ color: 'var(--fg3)' }}>Черновик</span>
              )}
              {!isActiveVersion && (
                <Button size="sm" variant="outline" className="ml-auto h-6 px-2 text-[11px]"
                  onClick={() => {
                    if (confirm(`Активировать версию ${version}? Текущая активная версия будет отключена.`))
                      activate.mutate({ p_category_id: categoryId, p_version: version })
                  }}>
                  Активировать
                </Button>
              )}
            </div>
            <div className="grid bg-muted/20 border-b border-border/60" style={{ gridTemplateColumns: COL }}>
              {['Порода', 'Пол', 'Возраст', 'Вес', 'BCS', 'Prio', ''].map((h, i) => (
                <div key={i} className="h-[30px] px-3 flex items-center text-[11px] font-medium border-r border-border/60 last:border-r-0" style={{ color: 'var(--fg2)' }}>{h}</div>
              ))}
            </div>
            {versionRules.map(r => (
              <div key={r.id} className="grid border-b border-border/60 last:border-b-0" style={{ gridTemplateColumns: COL }}>
                <div className="h-[34px] px-3 flex items-center border-r border-border/60 text-[12px] truncate">{r.breed_group ? BREED[r.breed_group as keyof typeof BREED] : 'любая'}</div>
                <div className="h-[34px] px-3 flex items-center border-r border-border/60 text-[12px]">{r.sex ? SEX[r.sex as keyof typeof SEX] : 'любой'}</div>
                <div className="h-[34px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono">{range(r.age_min_months, r.age_max_months, 'мес')}</div>
                <div className="h-[34px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono">{range(r.weight_min_kg, r.weight_max_kg, 'кг')}</div>
                <div className="h-[34px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono">{r.bcs_min == null && r.bcs_max == null ? 'любой' : `${r.bcs_min ?? '…'}–${r.bcs_max ?? '∞'}`}</div>
                <div className="h-[34px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono">{r.priority}</div>
                <div className="h-[34px] px-3 flex items-center text-[12px]">{r.is_active ? '✅' : '—'}</div>
              </div>
            ))}
          </div>
        )
      })}

      {showAdd && (
        <RuleDialog
          categoryId={categoryId}
          nextVersion={maxVersion + 1}
          stagedVersions={stagedVersions}
          onClose={() => setShowAdd(false)}
          onSaved={() => { refetch(); setShowAdd(false) }}
        />
      )}
    </div>
  )
}

function RuleDialog({
  categoryId, nextVersion, stagedVersions, onClose, onSaved,
}: {
  categoryId: string
  nextVersion: number
  stagedVersions: number[]
  onClose: () => void
  onSaved: () => void
}) {
  const [targetVersion, setTargetVersion] = useState<string>('new')
  const [breed, setBreed] = useState<string>(ANY)
  const [sex, setSex] = useState<string>(ANY)
  const [ageMin, setAgeMin] = useState('')
  const [ageMax, setAgeMax] = useState('')
  const [weightMin, setWeightMin] = useState('')
  const [weightMax, setWeightMax] = useState('')
  const [bcsMin, setBcsMin] = useState('')
  const [bcsMax, setBcsMax] = useState('')
  const [priority, setPriority] = useState('0')

  const setRule = useRpcMutation<Record<string, unknown>, { ok: boolean; error?: string }>(
    'rpc_admin_set_category_rule',
    {
      onSuccess: (data) => {
        if (!data?.ok) { toast.error(ERR[data?.error ?? ''] ?? data?.error ?? 'Ошибка'); return }
        toast.success('Правило добавлено (черновик). Активируйте версию, чтобы применить.')
        onSaved()
      },
    },
  )

  const numOrNull = (s: string) => (s.trim() === '' ? null : Number(s))

  function handleSave() {
    setRule.mutate({
      p_category_id: categoryId,
      p_breed_group: breed === ANY ? null : breed,
      p_sex: sex === ANY ? null : sex,
      p_age_min: numOrNull(ageMin),
      p_age_max: numOrNull(ageMax),
      p_weight_min: numOrNull(weightMin),
      p_weight_max: numOrNull(weightMax),
      p_bcs_min: numOrNull(bcsMin),
      p_bcs_max: numOrNull(bcsMax),
      p_priority: Number(priority) || 0,
      p_version: targetVersion === 'new' ? null : Number(targetVersion),
    })
  }

  return (
    <Dialog open onOpenChange={v => !v && onClose()}>
      <DialogContent className="max-w-lg">
        <DialogHeader><DialogTitle>Добавить правило</DialogTitle></DialogHeader>
        <div className="space-y-3 py-2">
          <div>
            <Label className="text-sm">Версия</Label>
            <Select value={targetVersion} onValueChange={setTargetVersion}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="new">Новая версия ({nextVersion}) — черновик</SelectItem>
                {stagedVersions.map(v => <SelectItem key={v} value={String(v)}>Версия {v} (черновик)</SelectItem>)}
              </SelectContent>
            </Select>
            <p className="text-[10px] text-muted-foreground mt-1">Новые правила добавляются в черновик; активная версия не меняется до нажатия «Активировать».</p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-sm">Порода</Label>
              <Select value={breed} onValueChange={setBreed}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value={ANY}>Любая</SelectItem>
                  {Object.entries(BREED).map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div>
              <Label className="text-sm">Пол</Label>
              <Select value={sex} onValueChange={setSex}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value={ANY}>Любой</SelectItem>
                  {Object.entries(SEX).map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-sm">Возраст, мес (мин / макс)</Label>
              <div className="flex gap-2">
                <Input type="number" placeholder="мин" value={ageMin} onChange={e => setAgeMin(e.target.value)} min={0} />
                <Input type="number" placeholder="макс" value={ageMax} onChange={e => setAgeMax(e.target.value)} min={0} />
              </div>
            </div>
            <div>
              <Label className="text-sm">Вес, кг (мин / макс)</Label>
              <div className="flex gap-2">
                <Input type="number" placeholder="мин" value={weightMin} onChange={e => setWeightMin(e.target.value)} min={0} />
                <Input type="number" placeholder="макс" value={weightMax} onChange={e => setWeightMax(e.target.value)} min={0} />
              </div>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-sm">BCS (мин / макс) — опц.</Label>
              <div className="flex gap-2">
                <Input type="number" step="0.1" placeholder="мин" value={bcsMin} onChange={e => setBcsMin(e.target.value)} />
                <Input type="number" step="0.1" placeholder="макс" value={bcsMax} onChange={e => setBcsMax(e.target.value)} />
              </div>
            </div>
            <div>
              <Label className="text-sm">Priority</Label>
              <Input type="number" value={priority} onChange={e => setPriority(e.target.value)} />
              <p className="text-[10px] text-muted-foreground mt-1">Выше = приоритетнее при совпадении.</p>
            </div>
          </div>
        </div>
        <DialogFooter className="gap-2">
          <Button variant="outline" onClick={onClose}>Отмена</Button>
          <Button onClick={handleSave} disabled={setRule.isPending}>
            {setRule.isPending ? 'Сохранение…' : 'Добавить'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

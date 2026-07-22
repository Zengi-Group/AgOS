/**
 * Consulting Dashboard — список инвестиционных проектов
 * Route: /admin/consulting
 * RPC: rpc_list_consulting_projects, rpc_create_consulting_project
 */
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Plus, Calculator, LayoutGrid, ChevronDown, ArrowUpDown, ArrowRight } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectTrigger, SelectValue, SelectContent, SelectItem } from '@/components/ui/select'
import { cn } from '@/lib/utils'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { useAuth } from '@/hooks/useAuth'
import { useAdminOrgs } from '@/hooks/admin/useAdminOrgs'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

interface ConsultingProject {
  id: string
  name: string
  farm_type: string
  status: string
  created_at: string
  updated_at: string
  latest_version: {
    version_number: number
    calculated_at: string
    npv: number | null
    irr: number | null
  } | null
}

/* ── Статус: точка + текст ── */
const STATUS_CONFIG: Record<string, { dotClass: string; label: string }> = {
  draft:       { dotClass: 'bg-[var(--fg3)]',     label: 'Черновик'  },
  calculating: { dotClass: 'bg-[var(--amber)]',   label: 'Расчёт...' },
  calculated:  { dotClass: 'bg-[var(--emerald)]', label: 'Рассчитан' },
  archived:    { dotClass: 'bg-[var(--bd-h)]',    label: 'Архив'     },
}

/* ── Цвет аватара по хэшу имени ── */
const AVATAR_COLORS = [
  { bg: 'hsl(240 40% 93%)', text: 'hsl(240 50% 38%)' },
  { bg: 'hsl(280 35% 93%)', text: 'hsl(280 45% 38%)' },
  { bg: 'hsl(145 40% 90%)', text: 'hsl(145 48% 28%)' },
  { bg: 'hsl(32 55% 90%)',  text: 'hsl(32 55% 32%)' },
  { bg: 'hsl(0 38% 92%)',   text: 'hsl(0 45% 38%)' },
  { bg: 'hsl(190 42% 90%)', text: 'hsl(190 48% 28%)' },
]

function avatarStyle(name: string) {
  const hash = name.split('').reduce((acc, c) => acc + c.charCodeAt(0), 0)
  return AVATAR_COLORS[hash % AVATAR_COLORS.length]!
}

const COL_TEMPLATE = 'minmax(200px,2fr) 120px 130px 90px 110px'

export function ConsultingDashboard() {
  const navigate = useNavigate()
  const { organization, isAdmin, isExpert } = useAuth()
  const [projects, setProjects] = useState<ConsultingProject[]>([])
  const [loading, setLoading] = useState(true)
  const [showCreate, setShowCreate] = useState(false)
  const [newName, setNewName] = useState('')
  const [newOrgId, setNewOrgId] = useState('')
  const [creating, setCreating] = useState(false)

  const orgId = organization?.id
  // TURAN admin/expert accounts have no farmer organization_id of their own (P2) —
  // they still need to see/create projects across client orgs (DEF-CONSULTING-AUTH-02).
  const canManageAllOrgs = isAdmin || isExpert
  const { data: clientOrgs } = useAdminOrgs('')

  useSetTopbar({
    title: 'Инвестиционные проекты',
    titleIcon: <LayoutGrid size={15} />,
    actions: (
      <Button onClick={() => setShowCreate(true)} size="sm" className="h-7 px-3 text-[12px] font-medium">
        <Plus className="mr-1.5 h-3 w-3" />
        Новый проект
      </Button>
    ),
  })

  const loadProjects = async () => {
    if (!orgId && !canManageAllOrgs) { setLoading(false); return }
    setLoading(true)
    const { data, error } = await supabase.rpc('rpc_list_consulting_projects', {
      p_organization_id: orgId ?? null,
    })
    if (error) {
      toast.error('Ошибка загрузки проектов')
      console.error(error)
    } else {
      setProjects(data || [])
    }
    setLoading(false)
  }

  useEffect(() => { loadProjects() }, [orgId, canManageAllOrgs])

  const handleCreate = async () => {
    if (!newOrgId || !newName.trim()) return
    setCreating(true)
    const { data, error } = await supabase.rpc('rpc_create_consulting_project', {
      p_organization_id: newOrgId,
      p_name: newName.trim(),
      p_farm_type: 'beef_reproducer',
    })
    setCreating(false)
    if (error) {
      toast.error('Ошибка создания проекта')
      console.error(error)
    } else {
      toast.success('Проект создан')
      setShowCreate(false)
      setNewName('')
      setNewOrgId('')
      navigate(`/admin/consulting/${data}/edit`)
    }
  }

  const formatNumber = (n: number | null) => {
    if (n === null || n === undefined) return '—'
    return new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 0 }).format(n)
  }

  const formatPercent = (n: number | null) => {
    if (n === null || n === undefined || isNaN(n)) return '—'
    return `${(n * 100).toFixed(1)}%`
  }

  const formatDate = (d: string) =>
    new Date(d).toLocaleDateString('ru-RU', { day: 'numeric', month: 'short' })

  if (loading) {
    return (
      <div className="page">
        <div className="flex flex-col border border-border/60 rounded-[8px] overflow-hidden bg-background">
          {/* View selector skeleton */}
          <div className="flex items-center h-10 px-4 border-b border-border/60">
            <Skeleton className="h-[26px] w-32 rounded-md" />
          </div>
          {/* Table header skeleton */}
          <div className="grid border-b border-border/60 bg-muted/40" style={{ gridTemplateColumns: COL_TEMPLATE }}>
            {[200, 120, 130, 90, 110].map((w, i) => (
              <div key={i} className="h-[34px] px-3 flex items-center border-r border-border/60 last:border-r-0">
                <Skeleton className="h-3" style={{ width: w * 0.4 }} />
              </div>
            ))}
          </div>
          {/* Row skeletons */}
          {[1, 2, 3].map(i => (
            <div key={i} className="grid border-b border-border/60" style={{ gridTemplateColumns: COL_TEMPLATE }}>
              <div className="h-[38px] px-3 flex items-center gap-2 border-r border-border/60">
                <Skeleton className="w-[22px] h-[22px] rounded-[5px] flex-shrink-0" />
                <Skeleton className="h-4 w-36" />
              </div>
              <div className="h-[38px] px-3 flex items-center gap-1.5 border-r border-border/60">
                <Skeleton className="w-1.5 h-1.5 rounded-full" />
                <Skeleton className="h-3 w-16" />
              </div>
              <div className="h-[38px] px-3 flex items-center justify-end border-r border-border/60">
                <Skeleton className="h-4 w-20" />
              </div>
              <div className="h-[38px] px-3 flex items-center justify-end border-r border-border/60">
                <Skeleton className="h-4 w-12" />
              </div>
              <div className="h-[38px] px-3 flex items-center">
                <Skeleton className="h-3 w-16" />
              </div>
            </div>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="page">
      <div className="flex flex-col border border-border/60 rounded-[8px] overflow-hidden bg-background">

        {/* ── Переключатель вида ── */}
        <div className="flex items-center h-10 px-4 border-b border-border/60 gap-2">
          <div className="h-[26px] px-2.5 rounded-md border border-border/60 text-[12px] flex items-center gap-1.5 cursor-pointer select-none" style={{ color: 'var(--fg)' }}>
            <LayoutGrid className="w-3 h-3 opacity-50" />
            Все проекты
            <ChevronDown className="w-3 h-3 opacity-40 ml-0.5" />
          </div>
        </div>

        {/* ── ТАБЛИЦА ── */}
        {projects.length === 0 ? (
          <Card className="rounded-none border-0">
            <CardContent className="flex flex-col items-center py-12">
              <Calculator className="mb-4 h-12 w-12 text-muted-foreground" />
              <h2 className="text-lg font-medium">Нет проектов</h2>
              <p className="mt-2 text-sm text-muted-foreground">
                Создайте первый инвестиционный проект для расчёта финансовой модели.
              </p>
              <Button onClick={() => setShowCreate(true)} className="mt-4" size="sm">
                <Plus className="mr-2 h-4 w-4" />
                Создать проект
              </Button>
            </CardContent>
          </Card>
        ) : (
          <>
            {/* Заголовок таблицы */}
            <div className="grid border-b border-border/60 bg-muted/40" style={{ gridTemplateColumns: COL_TEMPLATE }}>
              <div className="h-[34px] px-3 flex items-center gap-1 text-[11px] font-medium text-muted-foreground border-r border-border/60">
                Проект <ArrowUpDown className="w-2.5 h-2.5 opacity-40" />
              </div>
              <div className="h-[34px] px-3 flex items-center text-[11px] font-medium text-muted-foreground border-r border-border/60">
                Статус
              </div>
              <div className="h-[34px] px-3 flex items-center justify-end text-[11px] font-medium text-muted-foreground border-r border-border/60">
                NPV, тыс.
              </div>
              <div className="h-[34px] px-3 flex items-center justify-end text-[11px] font-medium text-muted-foreground border-r border-border/60">
                IRR
              </div>
              <div className="h-[34px] px-3 flex items-center text-[11px] font-medium text-muted-foreground">
                Обновлён
              </div>
            </div>

            {/* Строки */}
            {projects.map(p => {
              const av = avatarStyle(p.name)
              const st = STATUS_CONFIG[p.status] ?? { dotClass: 'bg-[var(--fg3)]', label: p.status }
              return (
                <div
                  key={p.id}
                  onClick={() => navigate(`/admin/consulting/${p.id}`)}
                  className="grid border-b border-border/60 cursor-pointer hover:bg-muted/40 transition-colors group"
                  style={{ gridTemplateColumns: COL_TEMPLATE }}
                >
                  {/* Проект */}
                  <div className="h-[38px] px-3 flex items-center gap-2 border-r border-border/60 min-w-0">
                    <div
                      className="w-[22px] h-[22px] rounded-[5px] flex items-center justify-center text-[10px] font-semibold flex-shrink-0"
                      style={{ background: av.bg, color: av.text }}
                    >
                      {p.name.slice(0, 2).toUpperCase()}
                    </div>
                    <span className="text-[13px] font-medium truncate">{p.name}</span>
                    <ArrowRight className="w-3 h-3 text-muted-foreground opacity-0 group-hover:opacity-60 transition-opacity ml-auto flex-shrink-0" />
                  </div>

                  {/* Статус */}
                  <div className="h-[38px] px-3 flex items-center gap-1.5 border-r border-border/60">
                    <span className={cn('w-1.5 h-1.5 rounded-full flex-shrink-0', st.dotClass)} />
                    <span className="text-[12px] text-muted-foreground">{st.label}</span>
                  </div>

                  {/* NPV */}
                  <div className="h-[38px] px-3 flex items-center justify-end border-r border-border/60">
                    {p.latest_version ? (
                      <span className={cn(
                        'text-[13px] font-medium tabular-nums',
                        p.latest_version.npv === null ? 'text-muted-foreground' :
                        p.latest_version.npv < 0 ? 'text-destructive' : 'text-[var(--emerald)]'
                      )}>
                        {formatNumber(p.latest_version.npv)}
                      </span>
                    ) : (
                      <span className="text-[13px] text-muted-foreground">—</span>
                    )}
                  </div>

                  {/* IRR */}
                  <div className="h-[38px] px-3 flex items-center justify-end border-r border-border/60">
                    {p.latest_version ? (
                      <span className={cn(
                        'text-[13px] font-medium tabular-nums',
                        p.latest_version.irr === null ? 'text-muted-foreground' :
                        p.latest_version.irr < 0 ? 'text-destructive' : 'text-[var(--emerald)]'
                      )}>
                        {formatPercent(p.latest_version.irr)}
                      </span>
                    ) : (
                      <span className="text-[13px] text-muted-foreground">—</span>
                    )}
                  </div>

                  {/* Обновлён */}
                  <div className="h-[38px] px-3 flex items-center">
                    <span className="text-[12px] text-muted-foreground">{formatDate(p.updated_at)}</span>
                  </div>
                </div>
              )
            })}

            {/* Футер */}
            <div className="grid bg-muted/40" style={{ gridTemplateColumns: COL_TEMPLATE }}>
              <div className="h-[28px] px-3 flex items-center">
                <span className="text-[11px] text-muted-foreground">
                  <span className="font-medium" style={{ color: 'var(--fg)' }}>{projects.length}</span> проектов
                </span>
              </div>
              <div className="h-[28px]" />
              <div className="h-[28px]" />
              <div className="h-[28px]" />
              <div className="h-[28px]" />
            </div>
          </>
        )}
      </div>

      {/* Create dialog */}
      <Dialog open={showCreate} onOpenChange={setShowCreate}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Новый инвестиционный проект</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label>Организация-клиент</Label>
              <Select value={newOrgId} onValueChange={setNewOrgId}>
                <SelectTrigger><SelectValue placeholder="Выберите организацию" /></SelectTrigger>
                <SelectContent>
                  {(clientOrgs ?? []).map(o => (
                    <SelectItem key={o.id} value={o.id}>{o.legal_name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label>Название проекта</Label>
              <Input
                placeholder="Например: Ферма Караарна 300 голов"
                value={newName}
                onChange={e => setNewName(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && handleCreate()}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setShowCreate(false)}>Отмена</Button>
            <Button onClick={handleCreate} disabled={!newOrgId || !newName.trim() || creating}>
              {creating ? 'Создание...' : 'Создать'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

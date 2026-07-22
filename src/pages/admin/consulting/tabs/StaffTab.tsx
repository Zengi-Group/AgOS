import { useState, useCallback, useMemo } from 'react'
import { useParams } from 'react-router-dom'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useProjectData, fmt, cacheResults } from './usProjectData'
import { useAuth } from '@/hooks/useAuth'
import { calculateProject } from '@/lib/consulting-api'
import { toast } from 'sonner'
import { Plus, Trash2, Calculator } from 'lucide-react'

/* ------------------------------------------------------------------ */
/*  Staff position catalog                                             */
/* ------------------------------------------------------------------ */
interface CatalogEntry {
  code: string
  name: string
  category: 'production' | 'admin'
  defaultFte: number
  defaultSalary: number
}

const STAFF_CATALOG: CatalogEntry[] = [
  // Производственный
  { code: 'director', name: 'Директор фермы', category: 'production', defaultFte: 1.0, defaultSalary: 600 },
  { code: 'vet', name: 'Ветеринар', category: 'production', defaultFte: 0.5, defaultSalary: 400 },
  { code: 'cook', name: 'Повар', category: 'production', defaultFte: 0.5, defaultSalary: 300 },
  { code: 'tractor', name: 'Тракторист', category: 'production', defaultFte: 1.0, defaultSalary: 400 },
  { code: 'zootechnician', name: 'Зоотехник', category: 'production', defaultFte: 0.5, defaultSalary: 450 },
  { code: 'guard', name: 'Сторож', category: 'production', defaultFte: 1.0, defaultSalary: 200 },
  { code: 'herder', name: 'Скотник', category: 'production', defaultFte: 1.0, defaultSalary: 250 },
  // Административный
  { code: 'accountant', name: 'Бухгалтер', category: 'admin', defaultFte: 0.3, defaultSalary: 300 },
  { code: 'manager', name: 'Управляющий', category: 'admin', defaultFte: 1.0, defaultSalary: 500 },
  { code: 'secretary', name: 'Секретарь', category: 'admin', defaultFte: 0.5, defaultSalary: 200 },
]

/* ------------------------------------------------------------------ */
/*  KZ tax calc (mirrors staff.py exactly)                             */
/* ------------------------------------------------------------------ */
const NET_TO_GROSS = 1.21
const SO_RATE = 0.035
const SN_RATE = 0.095
const OSMS_EMPLOYER_RATE = 0.03
const OSMS_EMPLOYEE_RATE = 0.02
const OPV_RATE = 0.10
const MIN_WAGE = 93.0 // тыс. тг
const MAX_SO_BASE = 7 * MIN_WAGE
const MAX_OSMS_BASE = 10 * MIN_WAGE

function calcTaxes(netSalary: number, fte: number) {
  const net = netSalary * fte
  const gross = net * NET_TO_GROSS
  const soBase = Math.min(gross, MAX_SO_BASE)
  const so = SO_RATE * soBase
  const opv = OPV_RATE * gross
  const osmsEmp = OSMS_EMPLOYEE_RATE * Math.min(gross, MAX_OSMS_BASE)
  const sn = Math.max(0, SN_RATE * (gross - opv - osmsEmp) - so)
  const osmsBase = Math.min(gross, MAX_OSMS_BASE)
  const osms = OSMS_EMPLOYER_RATE * osmsBase
  const total = gross + so + sn + osms
  return { net, gross, so, sn, osms, total }
}

/* ------------------------------------------------------------------ */
/*  Position row type                                                  */
/* ------------------------------------------------------------------ */
interface StaffRow {
  id: string // unique key for React
  code: string
  name: string
  category: 'production' | 'admin'
  fte: number
  net_salary: number
}

function makeId() {
  return Math.random().toString(36).slice(2, 9)
}

/* ------------------------------------------------------------------ */
/*  Component                                                          */
/* ------------------------------------------------------------------ */
export function StaffTab() {
  const { projectId } = useParams()
  const { organization } = useAuth()
  const { project, version, loading } = useProjectData()
  // Project's own org, not the viewer's — admin/expert have none of their own
  // (DEF-CONSULTING-AUTH-02); calculateProject matches against the project's
  // real org, not the caller's identity.
  const orgId = project?.organization_id ?? organization?.id

  const [calculating, setCalculating] = useState(false)

  // Initialize rows from saved input_params or defaults
  const initialRows = useMemo((): StaffRow[] => {
    const saved = version?.input_params?.staff_positions
    if (Array.isArray(saved) && saved.length > 0) {
      return saved.map((p: any) => ({
        id: makeId(),
        code: p.code || '',
        name: p.name || '',
        category: p.category || 'production',
        fte: p.fte ?? 1,
        net_salary: p.net_salary ?? 0,
      }))
    }
    // Default 7 positions (synced with staff.py fallback)
    return [
      { id: makeId(), code: 'director', name: 'Директор фермы', category: 'production', fte: 1.0, net_salary: 600 },
      { id: makeId(), code: 'vet', name: 'Ветеринар', category: 'production', fte: 0.5, net_salary: 400 },
      { id: makeId(), code: 'cook', name: 'Повар', category: 'production', fte: 0.5, net_salary: 300 },
      { id: makeId(), code: 'tractor', name: 'Тракторист', category: 'production', fte: 1.0, net_salary: 400 },
      { id: makeId(), code: 'herder', name: 'Скотник', category: 'production', fte: 1.0, net_salary: 250 },
      { id: makeId(), code: 'herder', name: 'Скотник', category: 'production', fte: 1.0, net_salary: 250 },
      { id: makeId(), code: 'accountant', name: 'Бухгалтер', category: 'admin', fte: 0.3, net_salary: 300 },
    ]
  }, [version])

  const [rows, setRows] = useState<StaffRow[]>(initialRows)

  // Update rows when version changes (e.g. after navigation back)
  // Only on initial load — not on every render
  const versionId = version?.id
  const [loadedVersionId, setLoadedVersionId] = useState<string | null>(null)
  if (versionId && versionId !== loadedVersionId) {
    setLoadedVersionId(versionId)
    const saved = version?.input_params?.staff_positions
    if (Array.isArray(saved) && saved.length > 0) {
      setRows(saved.map((p: any) => ({
        id: makeId(),
        code: p.code || '',
        name: p.name || '',
        category: p.category || 'production',
        fte: p.fte ?? 1,
        net_salary: p.net_salary ?? 0,
      })))
    }
  }

  const updateRow = useCallback((id: string, field: keyof StaffRow, value: any) => {
    setRows(prev => prev.map(r => r.id === id ? { ...r, [field]: value } : r))
  }, [])

  const removeRow = useCallback((id: string) => {
    setRows(prev => prev.filter(r => r.id !== id))
  }, [])

  const addFromCatalog = useCallback((entry: CatalogEntry) => {
    setRows(prev => [...prev, {
      id: makeId(),
      code: entry.code,
      name: entry.name,
      category: entry.category,
      fte: entry.defaultFte,
      net_salary: entry.defaultSalary,
    }])
  }, [])

  // Calculate & save
  const handleSaveAndRecalculate = async () => {
    if (!orgId || !projectId) return
    setCalculating(true)
    try {
      const staffPositions = rows.map(r => ({
        code: r.code,
        name: r.name,
        category: r.category,
        fte: r.fte,
        net_salary: r.net_salary,
      }))
      const currentParams = version?.input_params || {}
      const result = await calculateProject({
        project_id: projectId,
        organization_id: orgId,
        input_params: { ...currentParams, staff_positions: staffPositions },
      })
      cacheResults(projectId, result.results, { ...currentParams, staff_positions: staffPositions })
      toast.success(`Расчёт завершён. Версия ${result.version_number}`)
    } catch (err: any) {
      toast.error(err.message || 'Ошибка расчёта')
    } finally {
      setCalculating(false)
    }
  }

  // Totals
  const productionRows = rows.filter(r => r.category === 'production')
  const adminRows = rows.filter(r => r.category === 'admin')

  const totalProduction = productionRows.reduce((sum, r) => sum + calcTaxes(r.net_salary, r.fte).total, 0)
  const totalAdmin = adminRows.reduce((sum, r) => sum + calcTaxes(r.net_salary, r.fte).total, 0)
  const totalAll = totalProduction + totalAdmin
  const totalFte = rows.reduce((sum, r) => sum + r.fte, 0)

  if (loading) return (
    <div className="page space-y-2">
      <Skeleton className="h-5 w-44 mb-2" />
      {Array.from({ length: 10 }, (_, i) => (
        <div key={i} className="flex gap-3 items-center">
          <Skeleton className="h-3.5 grow" />
          <Skeleton className="h-3.5 w-16 shrink-0" />
          <Skeleton className="h-3.5 w-16 shrink-0" />
        </div>
      ))}
    </div>
  )

  if (!version?.input_params?.project_start_date) {
    return (
      <div className="page">
        <Card>
          <CardContent className="flex flex-col items-center py-12">
            <Calculator className="mb-4 h-10 w-10 text-muted-foreground" />
            <p className="text-muted-foreground">Сначала запустите расчёт из вкладки «Параметры», чтобы настроить штатное расписание.</p>
          </CardContent>
        </Card>
      </div>
    )
  }

  return (
    <div className="page space-y-4">
      {/* Staff table */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle>Штатное расписание</CardTitle>
          <Button
            size="sm"
            onClick={handleSaveAndRecalculate}
            disabled={calculating || rows.length === 0 || !version?.input_params?.project_start_date}
          >
            <Calculator className="h-4 w-4 mr-1" />
            {calculating ? 'Расчёт...' : 'Сохранить и пересчитать'}
          </Button>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border/40 bg-muted/40">
                <th className="text-left px-2 py-2 min-w-[200px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Позиция</th>
                <th className="text-center px-2 py-2 w-[100px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Категория</th>
                <th className="text-right px-2 py-2 w-[80px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">Единиц</th>
                <th className="text-right px-2 py-2 w-[120px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">ЗП нетто</th>
                <th className="text-right px-2 py-2 w-[120px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide">ЗП брутто</th>
                <th className="text-right px-2 py-2 w-[120px] text-[11px] font-medium text-muted-foreground uppercase tracking-wide" title="Год 1, без инфляции">Итого с налогами *</th>
                <th className="text-center px-2 py-2 w-[50px]"></th>
              </tr>
            </thead>
            <tbody>
              {rows.map(row => {
                const taxes = calcTaxes(row.net_salary, row.fte)
                return (
                  <tr key={row.id} className="border-b border-border/30 hover:bg-muted/20">
                    <td className="px-2 py-1.5">
                      <select
                        className="bg-transparent border border-border/50 rounded px-2 py-1 w-full text-sm"
                        value={row.code}
                        onChange={e => {
                          const entry = STAFF_CATALOG.find(c => c.code === e.target.value)
                          if (entry) {
                            setRows(prev => prev.map(r => r.id === row.id ? {
                              ...r,
                              code: entry.code,
                              name: entry.name,
                              category: entry.category,
                            } : r))
                          }
                        }}
                      >
                        {STAFF_CATALOG.map(c => (
                          <option key={c.code} value={c.code}>{c.name}</option>
                        ))}
                      </select>
                    </td>
                    <td className="px-2 py-1.5 text-center">
                      <span className={`text-xs px-2 py-0.5 rounded-full ${
                        row.category === 'admin'
                          ? 'bg-[var(--blue-m)] text-[var(--blue)]'
                          : 'bg-[var(--green-m)] text-[var(--green)]'
                      }`}>
                        {row.category === 'admin' ? 'АУП' : 'Произв.'}
                      </span>
                    </td>
                    <td className="px-2 py-1.5">
                      <input
                        type="number"
                        className="bg-transparent border border-border/50 rounded px-2 py-1 w-full text-right text-sm"
                        value={row.fte}
                        min={0}
                        max={10}
                        step={0.1}
                        onChange={e => updateRow(row.id, 'fte', parseFloat(e.target.value) || 0)}
                      />
                    </td>
                    <td className="px-2 py-1.5">
                      <input
                        type="number"
                        className="bg-transparent border border-border/50 rounded px-2 py-1 w-full text-right text-sm"
                        value={row.net_salary}
                        min={0}
                        step={10}
                        onChange={e => updateRow(row.id, 'net_salary', parseFloat(e.target.value) || 0)}
                      />
                    </td>
                    <td className="px-2 py-1.5 text-right font-mono text-muted-foreground">
                      {fmt(taxes.gross, 1)}
                    </td>
                    <td className="px-2 py-1.5 text-right font-mono font-semibold">
                      {fmt(taxes.total, 1)}
                    </td>
                    <td className="px-2 py-1.5 text-center">
                      <button
                        className="text-muted-foreground hover:text-[var(--red)] transition-colors"
                        onClick={() => removeRow(row.id)}
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>

          {/* Add position button */}
          <div className="mt-3 flex gap-2 flex-wrap">
            {STAFF_CATALOG.map(entry => (
              <Button
                key={entry.code}
                size="sm"
                variant="outline"
                className="text-xs"
                onClick={() => addFromCatalog(entry)}
              >
                <Plus className="h-3 w-3 mr-1" />
                {entry.name}
              </Button>
            ))}
          </div>
        </CardContent>
      </Card>

      {/* Summary */}
      <Card>
        <CardHeader className="pb-2">
          <CardTitle>Итого ФОТ (тыс. тг/мес)</CardTitle>
          <CardDescription>Суммарный фонд оплаты труда без учёта ежегодной индексации</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <p className="text-xs text-muted-foreground">Всего ед.</p>
              <p className="text-lg font-semibold">{fmt(totalFte, 1)}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Производственный</p>
              <p className="text-lg font-semibold text-[var(--green)]">{fmt(totalProduction, 0)}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Административный</p>
              <p className="text-lg font-semibold text-[var(--blue)]">{fmt(totalAdmin, 0)}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">Итого</p>
              <p className="text-lg font-semibold">{fmt(totalAll, 0)}</p>
            </div>
          </div>
        </CardContent>
      </Card>

      <p className="text-xs text-muted-foreground px-1">* Суммы показаны для Года 1 (без инфляции). В расчёте движка применяется ежегодная индексация 11%.</p>

      {/* Tax breakdown info */}
      <Card>
        <CardHeader className="pb-2">
          <CardTitle>Справка: налоговые ставки РК</CardTitle>
          <CardDescription>Ставки налогов и отчислений, применяемые в расчёте ФОТ</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm text-muted-foreground">
            <div>Нетто → Брутто: <span className="text-foreground">×{NET_TO_GROSS}</span></div>
            <div>СО: <span className="text-foreground">3.5%</span> (макс. 7×МЗП)</div>
            <div>СН: <span className="text-foreground">9.5%</span></div>
            <div>ОСМС работодатель: <span className="text-foreground">3%</span> (макс. 10×МЗП)</div>
            <div>ОСМС работник: <span className="text-foreground">2%</span></div>
            <div>ОПВ: <span className="text-foreground">10%</span></div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}

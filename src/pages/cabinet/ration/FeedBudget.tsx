/**
 * F18 — Бюджет кормления (Feed Budget)
 * Dok 6 Slice 3: /cabinet-legacy/ration/budget
 * Edge Function: get-feed-budget (POST /functions/v1/get-feed-budget)
 */
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'

interface BudgetFeed {
  feed_item_id: string
  feed_code: string
  feed_name: string
  daily_kg_total: number
  required_kg_period: number
  available_kg: number
  deficit_kg: number
  cost_estimate: number
  days_left: number
}

interface BudgetResult {
  per_head_per_day: {
    total_cost: number
    head_count: number
    feeds: Array<{ feed_code: string; feed_name: string; cost_per_head_per_day: number }>
  }
  total_budget: {
    period_days: number
    total_cost: number
    deficit_count: number
    days_until_shortage: number
    feeds: BudgetFeed[]
  }
}

const PERIODS = [
  { days: 30, label: '30 дней' },
  { days: 60, label: '60 дней' },
  { days: 90, label: '90 дней' },
]

function formatKg(kg: number): string {
  if (kg >= 1000) return `${(kg / 1000).toFixed(1)} т`
  return `${Math.round(kg)} кг`
}

export function FeedBudget() {
  const navigate = useNavigate()
  const { organization, farm } = useAuth()
  const [periodDays, setPeriodDays] = useState(30)
  const [budget, setBudget] = useState<BudgetResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!organization?.id || !farm?.id) return
    setLoading(true)
    setError(null)
    supabase.functions
      .invoke('get-feed-budget', {
        body: {
          organization_id: organization.id,
          farm_id: farm.id,
          period_days: periodDays,
        },
      })
      .then(({ data, error: err }) => {
        if (err) setError(err.message)
        else setBudget(data as BudgetResult)
      })
      .finally(() => setLoading(false))
  }, [organization?.id, farm?.id, periodDays])

  return (
    <div className="page space-y-6">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/ration')}>
          <ArrowLeft className="h-5 w-5" />
        </Button>
        <h1 className="text-2xl font-semibold">Бюджет кормления</h1>
      </div>

      {/* Period selector */}
      <div className="flex gap-2">
        {PERIODS.map((p) => (
          <Button
            key={p.days}
            variant={periodDays === p.days ? 'default' : 'outline'}
            size="sm"
            onClick={() => setPeriodDays(p.days)}
          >
            {p.label}
          </Button>
        ))}
      </div>

      {loading ? (
        <div className="space-y-4">
          <Skeleton className="h-24 w-full" />
          <Skeleton className="h-48 w-full" />
        </div>
      ) : error ? (
        <Card>
          <CardContent className="p-8 text-center text-destructive">
            {error}
          </CardContent>
        </Card>
      ) : !budget ? (
        <Card>
          <CardContent className="p-8 text-center">
            <p className="text-muted-foreground">Сначала рассчитайте рацион</p>
            <Button variant="outline" className="mt-3" onClick={() => navigate('/cabinet-legacy/ration')}>
              К рационам
            </Button>
          </CardContent>
        </Card>
      ) : (
        <>
          {/* Per-head summary card (CEO requirement) */}
          <Card>
            <CardHeader className="pb-2">
              <CardTitle className="text-lg">Стоимость на 1 голову</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-3xl font-bold">
                {budget.per_head_per_day.total_cost} ₸
                <span className="text-sm font-normal text-muted-foreground ml-2">
                  / голову / сутки
                </span>
              </div>
              <p className="text-sm text-muted-foreground mt-1">
                {budget.per_head_per_day.head_count} голов в стаде
              </p>
              {budget.per_head_per_day.feeds.length > 0 && (
                <div className="mt-3 space-y-1 text-sm">
                  {budget.per_head_per_day.feeds.map((f, i) => (
                    <div key={i} className="flex justify-between">
                      <span className="text-muted-foreground">{f.feed_name}</span>
                      <span>{f.cost_per_head_per_day} ₸</span>
                    </div>
                  ))}
                </div>
              )}
            </CardContent>
          </Card>

          {/* Total budget summary */}
          <Card>
            <CardHeader className="pb-2">
              <div className="flex items-center justify-between">
                <CardTitle className="text-lg">Итого на {periodDays} дней</CardTitle>
                <span className="text-xl font-bold">
                  {budget.total_budget.total_cost.toLocaleString('ru-RU')} ₸
                </span>
              </div>
              <div className="flex gap-3 text-sm">
                {budget.total_budget.deficit_count > 0 && (
                  <Badge variant="destructive">
                    {budget.total_budget.deficit_count} дефицит
                  </Badge>
                )}
                {budget.total_budget.days_until_shortage < 9999 && (
                  <span className="text-muted-foreground">
                    Хватает на {budget.total_budget.days_until_shortage} дн.
                  </span>
                )}
              </div>
            </CardHeader>
            <CardContent>
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b text-left text-muted-foreground">
                      <th className="pb-2">Корм</th>
                      <th className="pb-2 text-right">кг/день</th>
                      <th className="pb-2 text-right">Нужно</th>
                      <th className="pb-2 text-right">Есть</th>
                      <th className="pb-2 text-right">Дефицит</th>
                      <th className="pb-2 text-right">Дн.</th>
                    </tr>
                  </thead>
                  <tbody>
                    {budget.total_budget.feeds.map((f) => (
                      <tr
                        key={f.feed_item_id}
                        className={`border-b border-border/50 ${f.deficit_kg > 0 ? 'text-destructive' : ''}`}
                      >
                        <td className="py-2">{f.feed_name}</td>
                        <td className="py-2 text-right">{f.daily_kg_total}</td>
                        <td className="py-2 text-right">{formatKg(f.required_kg_period)}</td>
                        <td className="py-2 text-right">{formatKg(f.available_kg)}</td>
                        <td className="py-2 text-right">
                          {f.deficit_kg > 0 ? formatKg(f.deficit_kg) : '—'}
                        </td>
                        <td className="py-2 text-right">
                          <Badge variant={f.days_left < 14 ? 'destructive' : 'secondary'} className="text-xs">
                            {f.days_left >= 9999 ? '∞' : f.days_left}
                          </Badge>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  )
}

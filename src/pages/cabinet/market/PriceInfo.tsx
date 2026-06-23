/**
 * F09 — Справочные цены
 * Dok 6 Slice 5a: /cabinet-legacy/market/prices
 * D-S6-1 pattern: .from() for reference price_grids table
 */
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ArrowLeft, DollarSign } from 'lucide-react'
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { supabase } from '@/lib/supabase'

interface PriceRow {
  id: string; base_price_per_kg: number; premium_per_kg: number
  tsp_skus: { name_ru: string; code: string }; valid_from: string
}

const DISCLAIMER = 'Справочные цены являются индикативными рыночными ориентирами и не являются обязательными для применения. Участие добровольное.'

export function PriceInfo() {
  useSetTopbar({ title: 'Справочные цены', titleIcon: <DollarSign size={15} /> })
  const navigate = useNavigate()
  const [prices, setPrices] = useState<PriceRow[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.from('price_grids').select('id, base_price_per_kg, premium_per_kg, valid_from, tsp_skus!inner(name_ru, code)')
      .eq('is_active', true).order('base_price_per_kg', { ascending: false })
      .then(({ data }) => { setPrices((data as any) || []); setLoading(false) })
  }, [])

  return (
    <div className="space-y-6 p-6">
      <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/market')}><ArrowLeft className="h-5 w-5" /></Button>

      {/* Disclaimer — ALWAYS visible (Article 171) */}
      <Card className="border-amber-500/30 bg-amber-50/50">
        <CardContent className="p-4 text-sm text-amber-800">{DISCLAIMER}</CardContent>
      </Card>

      {loading ? <Skeleton className="h-48 w-full" /> : prices.length === 0 ? (
        <Card><CardContent className="p-8 text-center text-muted-foreground">Цены ещё не установлены</CardContent></Card>
      ) : (
        <Card>
          <CardContent className="p-0">
            <table className="w-full text-sm">
              <thead><tr className="border-b text-left text-muted-foreground">
                <th className="p-3">Категория</th>
                <th className="p-3 text-right">Базовая ₸/кг</th>
                <th className="p-3 text-right">Премиум ₸/кг</th>
              </tr></thead>
              <tbody>
                {prices.map(p => (
                  <tr key={p.id} className="border-b border-border/50">
                    <td className="p-3">{(p as any).tsp_skus?.name_ru || '—'}</td>
                    <td className="p-3 text-right font-medium">{p.base_price_per_kg?.toLocaleString('ru-RU')}</td>
                    <td className="p-3 text-right">{p.premium_per_kg > 0 ? `+${p.premium_per_kg?.toLocaleString('ru-RU')}` : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </CardContent>
        </Card>
      )}
    </div>
  )
}

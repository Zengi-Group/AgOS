/**
 * F22 — Сдвиг фаз (Cascade Preview)
 * Dok 6 Slice 4: /cabinet-legacy/plan/cascade/:phaseId
 * RPCs: fn_preview_cascade (RPC-36), fn_shift_phase_cascade (RPC-35)
 */
import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { ArrowLeft, ClipboardList } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'

import { toast } from 'sonner'

interface CascadeRow {
  phase_id: string
  name: string
  old_start: string
  new_start: string
  shift_days: number
}

export function CascadePreview() {
  useSetTopbar({ title: 'Каскадный план', titleIcon: <ClipboardList size={15} /> })
  const navigate = useNavigate()
  const { phaseId } = useParams()
  const { userContext } = useAuth()
  const [newDate, setNewDate] = useState('')
  const [preview, setPreview] = useState<CascadeRow[] | null>(null)
  const [loading, setLoading] = useState(false)

  async function handlePreview() {
    if (!newDate || !phaseId) return
    setLoading(true)
    try {
      const { data, error } = await supabase.rpc('fn_preview_cascade', {
        p_phase_id: phaseId,
        p_new_start_date: newDate,
      })
      if (error) throw error
      setPreview(data as CascadeRow[])
    } catch (err: any) {
      toast.error(err.message || 'Ошибка')
    } finally {
      setLoading(false)
    }
  }

  async function handleApply() {
    if (!preview || preview.length === 0 || !phaseId || !newDate) return
    if (!userContext?.user_id) { toast.error('Ошибка авторизации'); return }

    try {
      const { error } = await supabase.rpc('fn_shift_phase_cascade', {
        p_phase_id: phaseId,
        p_new_start_date: newDate,
        p_actor_id: userContext.user_id,
      })
      if (error) throw error
      toast.success('Даты обновлены')
      navigate('/cabinet-legacy/plan')
    } catch (err: any) {
      toast.error(err.message || 'Ошибка сдвига')
    }
  }

  return (
    <div className="page space-y-6">
      <Button variant="ghost" size="icon" onClick={() => navigate('/cabinet-legacy/plan')}>
        <ArrowLeft className="h-5 w-5" />
      </Button>

      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Новая дата начала</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label>Выберите новую дату</Label>
            <Input
              type="date"
              value={newDate}
              onChange={(e) => { setNewDate(e.target.value); setPreview(null) }}
            />
          </div>
          <Button onClick={handlePreview} disabled={!newDate || loading}>
            Предпросмотр каскада
          </Button>
        </CardContent>
      </Card>

      {preview && preview.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">Каскад изменений</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="pb-2">Фаза</th>
                    <th className="pb-2 text-right">Было</th>
                    <th className="pb-2 text-right">Станет</th>
                    <th className="pb-2 text-right">Сдвиг</th>
                  </tr>
                </thead>
                <tbody>
                  {preview.map((row) => (
                    <tr key={row.phase_id} className={`border-b border-border/50 ${row.shift_days !== 0 ? 'font-medium' : 'text-muted-foreground'}`}>
                      <td className="py-2">{row.name}</td>
                      <td className="py-2 text-right">{new Date(row.old_start).toLocaleDateString('ru-RU')}</td>
                      <td className="py-2 text-right">{new Date(row.new_start).toLocaleDateString('ru-RU')}</td>
                      <td className="py-2 text-right">
                        {row.shift_days !== 0 ? (
                          <Badge variant={row.shift_days > 0 ? 'secondary' : 'outline'}>
                            {row.shift_days > 0 ? '+' : ''}{row.shift_days} дн.
                          </Badge>
                        ) : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="flex gap-3 mt-4">
              <Button onClick={handleApply} className="flex-1">
                Применить сдвиг
              </Button>
              <Button variant="outline" onClick={() => navigate('/cabinet-legacy/plan')}>
                Отмена
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      {preview && preview.length === 0 && (
        <Card>
          <CardContent className="p-6 text-center text-muted-foreground">
            Нет фаз для каскадного сдвига
          </CardContent>
        </Card>
      )}
    </div>
  )
}

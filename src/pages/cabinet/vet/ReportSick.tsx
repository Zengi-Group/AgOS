import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Loader2, Send, ChevronDown, ChevronUp, Stethoscope } from 'lucide-react'
import { toast } from 'sonner'
import { Skeleton } from '@/components/ui/skeleton'
import { Textarea } from '@/components/ui/textarea'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'

export function ReportSick() {
  useSetTopbar({ title: 'Сообщить о болезни', titleIcon: <Stethoscope size={15} /> })
  const { userContext, isContextLoading, organization } = useAuth()
  const navigate = useNavigate()

  const farms = userContext?.farms || []
  const selectedFarm = farms.length === 1 ? farms[0] : null

  const [farmId, setFarmId] = useState(selectedFarm?.id || '')
  const [herdGroupId, setHerdGroupId] = useState('')
  const [symptomsText, setSymptomsText] = useState('')
  const [affectedHeads, setAffectedHeads] = useState('')
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [showOptional, setShowOptional] = useState(false)

  // Auto-select farm if single
  if (farms.length === 1 && !farmId && farms[0]) {
    setFarmId(farms[0].id)
  }

  const currentFarm = farms.find((f) => f.id === farmId)
  const herdGroups = currentFarm?.herd_groups || []

  const validate = () => {
    const errs: Record<string, string> = {}
    if (!farmId) {
      errs.farm = 'Выберите ферму'
    }
    if (!symptomsText.trim() || symptomsText.trim().length < 10) {
      errs.symptoms = 'Опишите подробнее — минимум 10 символов'
    }
    if (affectedHeads) {
      const n = parseInt(affectedHeads)
      if (isNaN(n) || n < 1) {
        errs.affected = 'Укажите число больше 0'
      }
    }
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSubmit = async () => {
    if (!validate()) return
    if (!organization?.id) return

    setIsSubmitting(true)
    try {
      const { data, error } = await supabase.rpc('rpc_create_vet_case', {
        p_organization_id: organization.id,
        p_farm_id: farmId,
        p_herd_group_id: herdGroupId || null,
        p_symptoms_text: symptomsText.trim(),
        p_severity: null,
        p_affected_heads: affectedHeads ? parseInt(affectedHeads) : null,
        p_created_via: 'cabinet_farmer',
      })

      if (error) {
        toast.error(error.message || 'Ошибка создания обращения')
        return
      }

      const result = data as { vet_case_id: string } | null
      if (!result?.vet_case_id) {
        navigate('/cabinet-legacy')
        return
      }

      toast.success('Обращение создано. AI анализирует...')
      navigate(`/cabinet-legacy/vet/${result.vet_case_id}`)

      // Async: create AI conversation and link it
      const gatewayUrl = import.meta.env.VITE_AI_GATEWAY_URL
      if (gatewayUrl) {
        fetch(`${gatewayUrl}/chat`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            organization_id: organization.id,
            user_message: `[VET_CASE:${result.vet_case_id}] ${symptomsText.trim()}`,
            farm_id: farmId,
            phone: userContext?.phone || undefined,
            channel: 'web',
          }),
        })
          .then(r => r.json())
          .then(d => {
            if (d?.conversation_id) {
              supabase.rpc('rpc_link_vet_case_conversation', {
                p_organization_id: organization.id,
                p_vet_case_id: result.vet_case_id,
                p_conversation_id: d.conversation_id,
              }).then(() => {})
            }
          })
          .catch(() => {})
      }
    } catch (err) {
      toast.error('Ошибка создания обращения')
      console.error(err)
    } finally {
      setIsSubmitting(false)
    }
  }

  if (isContextLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-28 w-full rounded-xl" />
        <Skeleton className="h-36 w-full rounded-xl" />
        <Skeleton className="h-12 w-full rounded-xl" />
      </div>
    )
  }

  const noFarms = farms.length === 0

  return (
    <div className="page space-y-5">

      {/* Subtitle */}
      <p className="text-sm text-[var(--fg2)]">AI проанализирует симптомы и предложит рекомендации</p>

      {/* No farms warning */}
      {noFarms && (
        <div className="p-4 rounded-xl" style={{ background: 'rgba(179,122,16,0.08)', border: '1px solid rgba(179,122,16,0.18)' }}>
          <p className="text-sm font-medium" style={{ color: 'var(--amber)' }}>Нет фермы</p>
          <p className="text-sm mt-0.5" style={{ color: 'var(--fg2)' }}>
            Сначала создайте ферму в разделе «Профиль».
          </p>
        </div>
      )}

      {/* Card: farm + group */}
      <div className="rounded-xl border border-[var(--bd)] bg-[var(--bg-c)] divide-y divide-[var(--bd)]">

        {/* Farm row */}
        <div className="px-4 py-3">
          <p className="text-xs text-[var(--fg2)] mb-2 font-medium uppercase tracking-wide">Ферма</p>
          {farms.length > 1 ? (
            <>
              <Select
                value={farmId || undefined}
                onValueChange={(v) => {
                  setFarmId(v)
                  setHerdGroupId('')
                  if (errors.farm) setErrors((prev) => ({ ...prev, farm: '' }))
                }}
              >
                <SelectTrigger
                  className="h-10 bg-transparent border-0 px-0 text-[var(--fg)] font-medium focus:ring-0 shadow-none"
                  style={{ borderColor: errors.farm ? 'var(--red)' : undefined }}
                >
                  <SelectValue placeholder="Выберите ферму..." />
                </SelectTrigger>
                <SelectContent>
                  {farms.map((f) => (
                    <SelectItem key={f.id} value={f.id}>{f.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {errors.farm && (
                <p className="text-xs mt-1" style={{ color: 'var(--red)' }}>{errors.farm}</p>
              )}
            </>
          ) : farms.length === 1 ? (
            <p className="text-sm font-medium text-[var(--fg)]">{farms[0]?.name}</p>
          ) : (
            <p className="text-sm text-[var(--fg3)]">—</p>
          )}
        </div>

        {/* Herd group row — only if groups exist */}
        {herdGroups.length > 0 && (
          <div className="px-4 py-3">
            <p className="text-xs text-[var(--fg2)] mb-2 font-medium uppercase tracking-wide">Группа животных</p>
            <Select value={herdGroupId || undefined} onValueChange={setHerdGroupId}>
              <SelectTrigger className="h-10 bg-transparent border-0 px-0 text-[var(--fg)] font-medium focus:ring-0 shadow-none">
                <SelectValue placeholder="Вся ферма / не знаю" />
              </SelectTrigger>
              <SelectContent>
                {herdGroups.map((g) => (
                  <SelectItem key={g.id} value={g.id}>
                    {g.animal_category_name || g.animal_category_code}
                    {g.breed_name ? ` · ${g.breed_name}` : ''}
                    {` — ${g.head_count} гол.`}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
      </div>

      {/* Card: symptoms */}
      <div className="rounded-xl border border-[var(--bd)] bg-[var(--bg-c)] p-4 space-y-2">
        <label className="text-xs text-[var(--fg2)] font-medium uppercase tracking-wide block">
          Что случилось <span style={{ color: 'var(--red)' }}>*</span>
        </label>
        <Textarea
          value={symptomsText}
          onChange={(e) => {
            setSymptomsText(e.target.value)
            if (errors.symptoms) setErrors((prev) => ({ ...prev, symptoms: '' }))
          }}
          placeholder="Например: телёнок не ест второй день, температура 40°, вялый, выделения из носа"
          className="min-h-[120px] resize-none bg-transparent border-[var(--bd)] focus-visible:border-[var(--cta)] text-sm"
          style={{ borderColor: errors.symptoms ? 'var(--red)' : undefined }}
          maxLength={5000}
        />
        <div className="flex items-center justify-between">
          {errors.symptoms ? (
            <p className="text-xs" style={{ color: 'var(--red)' }}>{errors.symptoms}</p>
          ) : (
            <span className="text-xs text-[var(--fg3)]">Чем подробнее — тем точнее анализ AI</span>
          )}
          <span className="text-xs text-[var(--fg3)] tabular-nums">{symptomsText.length}/5000</span>
        </div>
      </div>

      {/* Optional: affected heads — collapsible */}
      <button
        type="button"
        onClick={() => setShowOptional((v) => !v)}
        className="flex items-center gap-1.5 text-sm text-[var(--fg2)] hover:text-[var(--fg)] transition-colors"
      >
        {showOptional ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
        {showOptional ? 'Скрыть' : 'Добавить количество голов'}
      </button>

      {showOptional && (
        <div className="rounded-xl border border-[var(--bd)] bg-[var(--bg-c)] p-4 space-y-2">
          <label className="text-xs text-[var(--fg2)] font-medium uppercase tracking-wide block">
            Сколько голов болеет
          </label>
          <input
            type="number"
            value={affectedHeads}
            onChange={(e) => {
              setAffectedHeads(e.target.value)
              if (errors.affected) setErrors((prev) => ({ ...prev, affected: '' }))
            }}
            placeholder="0"
            min="1"
            className="w-full h-10 px-3 bg-[var(--bg-s)] border border-[var(--bd)] rounded-xl text-sm text-[var(--fg)] outline-none focus:border-[var(--cta)] transition-colors"
            style={{ borderColor: errors.affected ? 'var(--red)' : undefined }}
          />
          {errors.affected && (
            <p className="text-xs" style={{ color: 'var(--red)' }}>{errors.affected}</p>
          )}
        </div>
      )}

      {/* Submit */}
      <button
        onClick={handleSubmit}
        disabled={isSubmitting || noFarms}
        className="w-full h-12 rounded-xl text-sm font-semibold flex items-center justify-center gap-2 transition-opacity disabled:opacity-40"
        style={{ background: 'var(--cta)', color: 'var(--cta-fg)' }}
      >
        {isSubmitting ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <Send className="h-4 w-4" />
        )}
        {isSubmitting ? 'Отправка...' : 'Отправить на анализ AI'}
      </button>

    </div>
  )
}

/**
 * /cabinet-legacy/ration/calculator
 * Quick NASEM ration calculator — result is NOT saved to farm rations.
 * Farmer inputs group params + available feeds → gets instant NASEM ration.
 * Optional: "Save as farm ration" saves via calculate-ration edge function.
 */
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2, Calculator as CalcIcon, ChevronDown, AlertTriangle, CheckCircle2, Save } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'
import { toast } from 'sonner'

// ── Types ──────────────────────────────────────────────────────────────────────
interface AnimalCategory { id: string; code: string; name_ru: string }
interface FeedItem { id: string; code: string; name_ru: string; category: string }

interface CalcResult {
  solver_status: string
  total_dm_kg: number
  total_cost_per_day: number
  nutrient_requirements: Record<string, number>
  nutrient_values: Record<string, number>
  nutrients_met: Record<string, boolean>
  deficiencies: string[]
  items: Array<{ feed_item_code: string; quantity_kg_per_day: number; cost_per_day: number }>
}

const OBJECTIVES = [
  { value: 'maintenance', label: 'Поддержание' },
  { value: 'growth', label: 'Рост (0.8 кг/сут)' },
  { value: 'finishing', label: 'Откорм (1.2 кг/сут)' },
  { value: 'gestation', label: 'Стельность' },
  { value: 'lactation', label: 'Лактация' },
]

const BAR_COLORS = ['var(--brand)', 'var(--blue)', 'var(--green)', 'var(--amber)', 'var(--fg3)']

// ── Field ──────────────────────────────────────────────────────────────────────
function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div style={{
      background: 'var(--bg)',
      border: '1px solid var(--bd)',
      borderRadius: 8,
      padding: '10px 14px',
    }}>
      <div style={{ fontSize: 10, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 4 }}>
        {label}
      </div>
      {children}
    </div>
  )
}

// ── Select ─────────────────────────────────────────────────────────────────────
function Select({ value, onChange, options }: {
  value: string
  onChange: (v: string) => void
  options: Array<{ value: string; label: string }>
}) {
  return (
    <div style={{ position: 'relative' }}>
      <select
        value={value}
        onChange={e => onChange(e.target.value)}
        style={{
          width: '100%', fontSize: 13, fontWeight: 600, color: 'var(--fg)',
          background: 'transparent', border: 'none', outline: 'none',
          appearance: 'none', cursor: 'pointer', paddingRight: 20,
        }}
      >
        {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      <ChevronDown size={13} style={{ position: 'absolute', right: 0, top: '50%', transform: 'translateY(-50%)', color: 'var(--fg3)', pointerEvents: 'none' }} />
    </div>
  )
}

// ── Number input ───────────────────────────────────────────────────────────────
function NumInput({ value, onChange, min }: { value: number; onChange: (v: number) => void; min?: number }) {
  return (
    <input
      type="number"
      value={value}
      min={min ?? 1}
      onChange={e => onChange(Number(e.target.value))}
      style={{
        width: '100%', fontSize: 13, fontWeight: 600, color: 'var(--fg)',
        background: 'transparent', border: 'none', outline: 'none',
      }}
    />
  )
}

// ── Main ───────────────────────────────────────────────────────────────────────
export function Calculator() {
  const navigate = useNavigate()
  const { organization, farm, userContext } = useAuth()

  // Form state
  const [categoryId, setCategoryId] = useState('')
  const [objective, setObjective] = useState('growth')
  const [weight, setWeight] = useState(300)
  const [headCount, setHeadCount] = useState(1)
  const [selectedFeeds, setSelectedFeeds] = useState<string[]>([])

  const [isCalculating, setIsCalculating] = useState(false)
  const [isSaving, setIsSaving] = useState(false)
  const [result, setResult] = useState<CalcResult | null>(null)

  // Load animal categories (DEF-RATION-SAVE-01: explicit params disambiguate overload)
  const { data: categories } = useRpc<AnimalCategory[]>(
    'rpc_list_animal_categories',
    { p_at_date: null, p_include_deprecated: false },
  )
  // Load feed items from inventory
  const { data: feedItems } = useRpc<FeedItem[]>(
    'rpc_list_feed_items', {},
  )

  // Herd groups from context (for category prefill)
  const herdGroups = userContext?.farms?.[0]?.herd_groups ?? []

  const categoryOptions = (categories ?? []).map(c => ({ value: c.id, label: c.name_ru }))
  const feedOptions = feedItems ?? []

  // Default category to first
  const effectiveCategoryId = categoryId || categoryOptions[0]?.value || ''

  function toggleFeed(id: string) {
    setSelectedFeeds(prev => prev.includes(id) ? prev.filter(f => f !== id) : [...prev, id])
  }

  function prefillFromGroup(groupId: string) {
    const g = herdGroups.find(h => h.id === groupId)
    if (!g) return
    setCategoryId(g.animal_category_id)
    setWeight(g.avg_weight_kg ?? 300)
    setHeadCount(g.head_count)
  }

  async function handleCalculate() {
    if (!organization?.id || !farm?.id) return
    if (!effectiveCategoryId) { toast.error('Выберите группу животных'); return }
    if (selectedFeeds.length === 0) { toast.error('Выберите хотя бы один корм'); return }

    setIsCalculating(true)
    setResult(null)
    try {
      const { data, error } = await supabase.functions.invoke('calculate-ration', {
        body: {
          organization_id: organization.id,
          farm_id: farm.id,
          animal_category_id: effectiveCategoryId,
          breed_id: null,
          avg_weight_kg: weight,
          head_count: headCount,
          objective,
          feed_item_ids: selectedFeeds,
          quick_mode: true, // не сохранять как рацион фермы
        },
      })
      if (error) throw error
      // Edge function returns ration_version.results
      setResult((data as any)?.results ?? data)
    } catch (err: any) {
      toast.error(err.message || 'Ошибка расчёта')
    } finally {
      setIsCalculating(false)
    }
  }

  async function handleSaveAsFarmRation() {
    if (!organization?.id || !farm?.id || !result) return
    setIsSaving(true)
    try {
      const { error } = await supabase.functions.invoke('calculate-ration', {
        body: {
          organization_id: organization.id,
          farm_id: farm.id,
          animal_category_id: effectiveCategoryId,
          breed_id: null,
          avg_weight_kg: weight,
          head_count: headCount,
          objective,
          feed_item_ids: selectedFeeds,
          quick_mode: false, // сохранить
        },
      })
      if (error) throw error
      toast.success('Рацион сохранён')
      navigate('/cabinet-legacy/ration/groups')
    } catch (err: any) {
      toast.error(err.message || 'Ошибка сохранения')
    } finally {
      setIsSaving(false)
    }
  }

  const items = result?.items ?? []
  const totalKg = items.reduce((s, i) => s + i.quantity_kg_per_day, 0)

  return (
    <div className="page" style={{ maxWidth: 720 }}>

      {/* Description */}
      <p style={{ fontSize: 13, color: 'var(--fg3)', marginBottom: 24 }}>
        Быстрый подбор рациона по нормам NASEM. Результат не сохраняется на ферму — можно сохранить вручную.
      </p>

      {/* Prefill from group */}
      {herdGroups.length > 0 && (
        <div style={{ marginBottom: 20 }}>
          <div style={{ fontSize: 11, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>
            Быстро заполнить из группы фермы
          </div>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {herdGroups.map(g => (
              <button
                key={g.id}
                onClick={() => prefillFromGroup(g.id)}
                style={{
                  fontSize: 12, fontWeight: 600, padding: '5px 12px',
                  borderRadius: 20, border: '1px solid var(--bd)',
                  background: 'var(--bg-c)', color: 'var(--fg2)', cursor: 'pointer',
                  transition: 'all 80ms',
                }}
                onMouseEnter={e => { e.currentTarget.style.background = 'var(--bg-m)'; e.currentTarget.style.color = 'var(--fg)' }}
                onMouseLeave={e => { e.currentTarget.style.background = 'var(--bg-c)'; e.currentTarget.style.color = 'var(--fg2)' }}
              >
                {g.animal_category_name}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Parameters */}
      <div style={{
        background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
        padding: '18px 20px', marginBottom: 16, boxShadow: 'var(--sh-sm)',
      }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 14 }}>
          Параметры
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <Field label="Половозрастная группа">
            <Select value={effectiveCategoryId} onChange={setCategoryId} options={categoryOptions} />
          </Field>
          <Field label="Цель">
            <Select value={objective} onChange={setObjective} options={OBJECTIVES} />
          </Field>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Средний вес, кг">
            <NumInput value={weight} onChange={setWeight} min={50} />
          </Field>
          <Field label="Количество голов">
            <NumInput value={headCount} onChange={setHeadCount} min={1} />
          </Field>
        </div>
      </div>

      {/* Feed selection */}
      <div style={{
        background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
        padding: '18px 20px', marginBottom: 20, boxShadow: 'var(--sh-sm)',
      }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 14 }}>
          Доступные корма {selectedFeeds.length > 0 && <span style={{ color: 'var(--brand)' }}>({selectedFeeds.length} выбрано)</span>}
        </div>
        {feedOptions.length === 0 ? (
          <p style={{ fontSize: 13, color: 'var(--fg3)', textAlign: 'center', padding: '12px 0' }}>
            Нет кормов на складе.{' '}
            <span
              onClick={() => navigate('/cabinet-legacy/feed')}
              style={{ color: 'var(--brand)', cursor: 'pointer', textDecoration: 'underline' }}
            >
              Добавить корма
            </span>
          </p>
        ) : (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {feedOptions.map(f => {
              const active = selectedFeeds.includes(f.id)
              return (
                <button
                  key={f.id}
                  onClick={() => toggleFeed(f.id)}
                  style={{
                    fontSize: 12, fontWeight: 600, padding: '6px 14px',
                    borderRadius: 20, cursor: 'pointer', transition: 'all 80ms',
                    border: active ? 'none' : '1px solid var(--bd)',
                    background: active ? 'var(--brand)' : 'var(--bg)',
                    color: active ? '#000' : 'var(--fg2)',
                  }}
                >
                  {f.code}
                </button>
              )
            })}
          </div>
        )}
      </div>

      {/* Calculate button */}
      <button
        onClick={handleCalculate}
        disabled={isCalculating}
        style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          width: '100%', padding: '12px', borderRadius: 10, border: 'none',
          background: 'var(--cta)', color: 'var(--cta-fg)',
          fontSize: 14, fontWeight: 700, cursor: 'pointer',
          opacity: isCalculating ? 0.6 : 1, marginBottom: 24, transition: 'opacity 150ms',
        }}
      >
        {isCalculating ? <Loader2 size={16} className="animate-spin" /> : <CalcIcon size={16} />}
        {isCalculating ? 'Рассчитываем…' : 'Рассчитать рацион'}
      </button>

      {/* Result */}
      {result && (
        <div style={{
          background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
          overflow: 'hidden', boxShadow: 'var(--sh-sm)',
        }}>
          {/* Header */}
          <div style={{ padding: '14px 20px', borderBottom: '1px solid var(--bd)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div>
              <div style={{ fontSize: 14, fontWeight: 700, color: 'var(--fg)' }}>Результат расчёта</div>
              <div style={{ fontSize: 11, color: 'var(--fg3)', marginTop: 2 }}>
                {result.solver_status === 'feasible' ? '✓ Рацион сбалансирован' : '⚠ Частично сбалансирован'}
              </div>
            </div>
            <button
              onClick={handleSaveAsFarmRation}
              disabled={isSaving}
              style={{
                display: 'flex', alignItems: 'center', gap: 6,
                fontSize: 12, fontWeight: 600, padding: '7px 14px', borderRadius: 8,
                border: '1px solid var(--bd)', background: 'var(--bg)',
                color: 'var(--fg2)', cursor: 'pointer', opacity: isSaving ? 0.5 : 1,
              }}
            >
              {isSaving ? <Loader2 size={13} className="animate-spin" /> : <Save size={13} />}
              Сохранить как рацион фермы
            </button>
          </div>

          <div style={{ padding: '18px 20px' }}>
            {/* NASEM norms */}
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
              Нормы NASEM
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 20 }}>
              {[
                { label: 'Сухое вещество', val: result.nutrient_requirements?.dm_kg?.toFixed(1) ?? '—', unit: 'кг/гол/сут' },
                { label: 'Обм. энергия', val: result.nutrient_requirements?.me_mj?.toFixed(1) ?? '—', unit: 'МДж/гол/сут' },
                { label: 'Сырой протеин', val: result.nutrient_requirements?.cp_g ? Math.round(result.nutrient_requirements.cp_g).toString() : '—', unit: 'г/гол/сут' },
              ].map(({ label, val, unit }) => (
                <div key={label} style={{ background: 'var(--bg)', border: '1px solid var(--bd)', borderRadius: 10, padding: '12px 14px' }}>
                  <div style={{ fontSize: 10, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.04em', marginBottom: 4 }}>{label}</div>
                  <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--fg)', lineHeight: 1 }}>{val}</div>
                  <div style={{ fontSize: 11, color: 'var(--fg3)', marginTop: 4 }}>{unit}</div>
                </div>
              ))}
            </div>

            {/* Feed rows */}
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
              Рацион (кг / голову / сутки)
            </div>
            {items.map((item, idx) => {
              const pct = totalKg > 0 ? (item.quantity_kg_per_day / totalKg) * 100 : 0
              return (
                <div key={item.feed_item_code} style={{
                  display: 'grid', gridTemplateColumns: '140px 1fr 90px',
                  gap: 12, alignItems: 'center',
                  padding: '10px 14px', background: 'var(--bg)', border: '1px solid var(--bd)',
                  borderRadius: 8, marginBottom: 6,
                }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{item.feed_item_code}</div>
                  <div style={{ height: 8, background: 'var(--bg-m)', borderRadius: 4, overflow: 'hidden' }}>
                    <div style={{ height: 8, borderRadius: 4, width: `${Math.min(pct, 100)}%`, background: BAR_COLORS[idx % BAR_COLORS.length] ?? 'var(--brand)', transition: 'width 0.4s ease' }} />
                  </div>
                  <div style={{ textAlign: 'right', fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>
                    {item.quantity_kg_per_day.toFixed(1)} кг
                  </div>
                </div>
              )
            })}

            {/* Итого */}
            <div style={{
              display: 'grid', gridTemplateColumns: '140px 1fr 90px',
              gap: 12, alignItems: 'center',
              padding: '10px 14px', background: 'var(--bg-m)', border: '1px solid var(--bd)',
              borderRadius: 8, marginBottom: 20,
            }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--fg)' }}>Итого</div>
              <div />
              <div style={{ textAlign: 'right', fontSize: 13, fontWeight: 700, color: 'var(--fg)' }}>{totalKg.toFixed(1)} кг</div>
            </div>

            {/* Deficiencies */}
            {(result.deficiencies?.length ?? 0) > 0 && (
              <div style={{
                background: 'rgba(224,96,80,0.08)', border: '1px solid rgba(224,96,80,0.25)',
                borderRadius: 8, padding: '10px 14px', display: 'flex', gap: 8, alignItems: 'flex-start',
              }}>
                <AlertTriangle size={14} style={{ color: 'var(--red)', marginTop: 2, flexShrink: 0 }} />
                <span style={{ fontSize: 13, color: 'var(--red)' }}>
                  Дефицит: {result.deficiencies.join(', ')}
                </span>
              </div>
            )}
            {(result.deficiencies?.length ?? 0) === 0 && result.solver_status === 'feasible' && (
              <div style={{
                background: 'rgba(94,196,122,0.08)', border: '1px solid rgba(94,196,122,0.25)',
                borderRadius: 8, padding: '10px 14px', display: 'flex', gap: 8, alignItems: 'center',
              }}>
                <CheckCircle2 size={14} style={{ color: 'var(--green)', flexShrink: 0 }} />
                <span style={{ fontSize: 13, color: 'var(--green)' }}>Все питательные нормы выполнены</span>
              </div>
            )}
          </div>
        </div>
      )}

      <div style={{ fontSize: 11, color: 'var(--fg3)', marginTop: 24, paddingTop: 12, borderTop: '1px solid var(--bd)' }}>
        ⚠ Питательность кормов — приблизительная (NASEM 2016). Требует валидации зоотехника перед применением.
      </div>
    </div>
  )
}

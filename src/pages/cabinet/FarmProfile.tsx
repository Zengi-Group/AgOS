import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import {
  Loader2, Plus, Pencil, AlertTriangle, X,
  Home, Calendar, ChevronRight, Activity, Leaf,
} from 'lucide-react'
import { toast } from 'sonner'
import { Skeleton } from '@/components/ui/skeleton'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'
import { StatusBadge } from '@/components/ui/status-badge'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import type { Farm, HerdGroup } from '@/contexts/AuthContext'

const SHELTER_TYPES = [
  { value: 'stall',    label: 'Стойловое (закрытое)' },
  { value: 'pasture',  label: 'Пастбищное (открытое)' },
  { value: 'mixed',    label: 'Смешанное' },
  { value: 'feedlot',  label: 'Откормочная площадка' },
]

const CALVING_SYSTEMS = [
  { value: 'spring',      label: 'Весенний (март–май)' },
  { value: 'autumn',      label: 'Осенний (сен–ноя)' },
  { value: 'year_round',  label: 'Круглогодичный' },
  { value: 'two_season',  label: 'Весна + осень' },
]

const ACTIVITY_TYPES = [
  { id: 'cow_calf',  label: 'Мясное маточное стадо' },
  { id: 'finishing', label: 'Откорм' },
  { id: 'dairy',     label: 'Молочное скотоводство' },
  { id: 'breeding',  label: 'Племенное разведение' },
  { id: 'mixed',     label: 'Смешанное' },
]

const ANIMAL_CATEGORIES = [
  { code: 'YOUNG_CALF',    name: 'Телята отъёмные (3-8 мес)' },
  { code: 'BULL_CALF',     name: 'Бычки (8-18 мес)' },
  { code: 'STEER',         name: 'Бычки на откорме (12-30 мес)' },
  { code: 'HEIFER_YOUNG',  name: 'Тёлки (8-18 мес)' },
  { code: 'HEIFER_PREG',   name: 'Нетели (18-30 мес)' },
  { code: 'COW',           name: 'Коровы (30+ мес)' },
  { code: 'COW_CULL',      name: 'Коровы выбракованные' },
  { code: 'BULL_BREEDING', name: 'Быки-производители' },
  { code: 'BULL_CULL',     name: 'Быки выбракованные' },
]

interface HerdGroupFormData {
  id: string | null
  animal_category_code: string
  head_count: string
  avg_weight_kg: string
  breed_id: string
}

const EMPTY_HERD_FORM: HerdGroupFormData = {
  id: null,
  animal_category_code: '',
  head_count: '',
  avg_weight_kg: '',
  breed_id: '',
}

// ── Sub-components ────────────────────────────────────────────────────────────

function CharRow({ icon, label, value }: { icon: React.ReactNode; label: string; value?: string | null }) {
  return (
    <div
      className="flex items-center gap-3 px-2 py-2 rounded-lg transition-colors"
      onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg)')}
      onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
    >
      <div
        className="w-8 h-8 rounded-md flex items-center justify-center shrink-0 border"
        style={{ background: 'var(--bg)', borderColor: 'var(--bd)', color: 'var(--fg2)' }}
      >
        {icon}
      </div>
      <div>
        <div className="text-[11px] mb-px" style={{ color: 'var(--fg3)' }}>{label}</div>
        <div className="text-[13px] font-semibold" style={{ color: value ? 'var(--fg)' : 'var(--fg3)' }}>
          {value || '—'}
        </div>
      </div>
    </div>
  )
}

// ── Main component ────────────────────────────────────────────────────────────

export function FarmProfile() {
  useSetTopbar({ title: 'Профиль фермы', titleIcon: <Leaf size={15} /> })
  const { userContext, isContextLoading, organization, refreshContext } = useAuth()
  const navigate = useNavigate()
  const farm = userContext?.farms?.[0] as Farm | undefined
  const membership = userContext?.memberships?.[0]

  // ── Farm form state ──────────────────────────────────────────────────────────
  const [isCreating, setIsCreating] = useState(false)
  const [isSheetOpen, setIsSheetOpen] = useState(false)
  const [farmName, setFarmName] = useState('')
  const [shelterType, setShelterType] = useState('')
  const [calvingSystem, setCalvingSystem] = useState('')
  const [isSavingFarm, setIsSavingFarm] = useState(false)
  const [farmNameError, setFarmNameError] = useState(false)

  // ── Activities ───────────────────────────────────────────────────────────────
  const [activities, setActivities] = useState<string[]>([])

  // ── Herd group form ──────────────────────────────────────────────────────────
  const [showHerdForm, setShowHerdForm] = useState(false)
  const [herdForm, setHerdForm] = useState<HerdGroupFormData>(EMPTY_HERD_FORM)
  const [isSavingHerd, setIsSavingHerd] = useState(false)
  const [herdErrors, setHerdErrors] = useState<Record<string, string>>({})
  const [breedsDb, setBreedsDb] = useState<Array<{ id: string; name: string }>>([])

  useEffect(() => {
    supabase.from('breeds').select('id, name_ru').eq('is_active', true).order('name_ru')
      .then(({ data }) => { if (data) setBreedsDb(data.map(b => ({ id: b.id, name: b.name_ru }))) })
  }, [])

  useEffect(() => {
    if (farm) {
      setFarmName(farm.name || '')
      setShelterType(farm.shelter_type || '')
      setCalvingSystem(farm.calving_system || '')
      setIsCreating(false)
    } else {
      setIsCreating(true)
    }
  }, [farm])

  // ── Sheet handlers ───────────────────────────────────────────────────────────
  const openSheet = () => {
    setFarmName(farm?.name || '')
    setShelterType(farm?.shelter_type || '')
    setCalvingSystem(farm?.calving_system || '')
    setFarmNameError(false)
    setIsSheetOpen(true)
  }

  const closeSheet = () => {
    setIsSheetOpen(false)
    setFarmName(farm?.name || '')
    setShelterType(farm?.shelter_type || '')
    setCalvingSystem(farm?.calving_system || '')
    setFarmNameError(false)
  }

  // ── Save farm ────────────────────────────────────────────────────────────────
  const handleSaveFarm = async (onSuccess?: () => void) => {
    if (!farmName.trim()) { setFarmNameError(true); toast.error('Введите название фермы'); return }
    setFarmNameError(false)
    if (!organization?.id) { toast.error('Организация не найдена. Перезагрузите страницу.'); return }
    setIsSavingFarm(true)
    try {
      const { error } = await supabase.rpc('rpc_upsert_farm', {
        p_organization_id: organization.id,
        p_farm_id: farm?.id || null,
        p_name: farmName.trim(),
        p_region_id: null,
        p_shelter_type: shelterType || null,
        p_calving_system: calvingSystem || null,
      })
      if (error) { toast.error(error.message || 'Ошибка сохранения'); return }
      toast.success(farm ? 'Данные фермы обновлены' : 'Ферма создана!')
      await refreshContext()
      setIsCreating(false)
      onSuccess?.()
    } catch (err) {
      toast.error('Ошибка сохранения')
      console.error(err)
    } finally {
      setIsSavingFarm(false)
    }
  }

  // ── Activities ───────────────────────────────────────────────────────────────
  const handleActivityToggle = async (activityId: string) => {
    if (!farm?.id) return
    const newActivities = activities.includes(activityId)
      ? activities.filter(a => a !== activityId)
      : [...activities, activityId]
    setActivities(newActivities)
    try {
      const { error } = await supabase.rpc('rpc_set_farm_activity_types', {
        p_organization_id: organization!.id,
        p_farm_id: farm.id,
        p_activity_types: newActivities,
      })
      if (error) { toast.error('Ошибка сохранения'); setActivities(activities) }
    } catch {
      setActivities(activities)
    }
  }

  // ── Herd group ───────────────────────────────────────────────────────────────
  const handleSaveHerdGroup = async () => {
    const errs: Record<string, string> = {}
    if (!herdForm.animal_category_code) errs.category = 'Выберите категорию'
    const headCount = parseInt(herdForm.head_count)
    if (!herdForm.head_count || isNaN(headCount) || headCount < 1) errs.head_count = 'Укажите количество голов'
    if (herdForm.avg_weight_kg) {
      const w = parseFloat(herdForm.avg_weight_kg)
      if (isNaN(w) || w < 1 || w > 2000) errs.avg_weight = 'Вес должен быть от 1 до 2000 кг'
    }
    setHerdErrors(errs)
    if (Object.keys(errs).length > 0) return
    if (!organization?.id || !farm?.id) { toast.error('Сначала сохраните ферму'); return }

    setIsSavingHerd(true)
    try {
      const { error } = await supabase.rpc('rpc_upsert_herd_group', {
        p_organization_id: organization.id,
        p_farm_id: farm.id,
        p_herd_group_id: herdForm.id || null,
        p_animal_category_code: herdForm.animal_category_code,
        p_head_count: parseInt(herdForm.head_count),
        p_avg_weight_kg: herdForm.avg_weight_kg ? parseFloat(herdForm.avg_weight_kg) : null,
        p_breed_id: herdForm.breed_id || null,
      })
      if (error) { toast.error(error.message || 'Ошибка сохранения'); return }
      toast.success(herdForm.id ? 'Группа обновлена' : 'Группа добавлена')
      setShowHerdForm(false)
      setHerdForm(EMPTY_HERD_FORM)
      await refreshContext()
    } catch (err) {
      toast.error('Ошибка сохранения')
      console.error(err)
    } finally {
      setIsSavingHerd(false)
    }
  }

  const editHerdGroup = (group: HerdGroup) => {
    setHerdForm({
      id: group.id,
      animal_category_code: group.animal_category_code,
      head_count: String(group.head_count),
      avg_weight_kg: group.avg_weight_kg ? String(group.avg_weight_kg) : '',
      breed_id: group.breed_id || '',
    })
    setShowHerdForm(true)
    setHerdErrors({})
  }

  // ── Derived ──────────────────────────────────────────────────────────────────
  const totalHeads = farm?.herd_groups?.reduce((s, g) => s + (g.head_count || 0), 0) || 0
  const groupCount = farm?.herd_groups?.length || 0
  const hasRestrictions = (userContext?.health_restrictions?.length || 0) > 0

  const groupsWithWeight = farm?.herd_groups?.filter(g => g.avg_weight_kg) || []
  const avgWeight = groupsWithWeight.length > 0
    ? Math.round(groupsWithWeight.reduce((s, g) => s + g.avg_weight_kg!, 0) / groupsWithWeight.length)
    : 0

  const membershipBadgeStatus =
    membership?.status === 'active'    ? 'approved' :
    membership?.status === 'applicant' ? 'submitted' : 'open'
  const membershipLabel =
    membership?.status === 'active'    ? 'Член ассоциации' :
    membership?.status === 'applicant' ? 'Заявка подана' : 'Зарегистрирован'

  const shelterLabel  = SHELTER_TYPES.find(s => s.value === farm?.shelter_type)?.label
  const calvingLabel  = CALVING_SYSTEMS.find(c => c.value === farm?.calving_system)?.label
  const groupWord = groupCount === 1 ? 'группа' : groupCount < 5 ? 'группы' : 'групп'

  // ── Loading ──────────────────────────────────────────────────────────────────
  if (isContextLoading) {
    return (
      <div className="page space-y-5">
        <Skeleton className="h-40 w-full rounded-xl" />
        <div className="grid gap-4" style={{ gridTemplateColumns: '1fr 420px' }}>
          <Skeleton className="h-56 rounded-xl" />
          <div className="space-y-4">
            <Skeleton className="h-36 rounded-xl" />
            <Skeleton className="h-16 rounded-xl" />
          </div>
        </div>
      </div>
    )
  }

  // ── Create-farm state ────────────────────────────────────────────────────────
  if (!farm || isCreating) {
    return (
      <div className="page">
        <p className="text-sm mb-6" style={{ color: 'var(--fg2)' }}>
          Добавьте информацию о вашем хозяйстве
        </p>

        <div className="space-y-4">
          <div>
            <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--fg2)' }}>
              Название фермы <span style={{ color: 'var(--red)' }}>*</span>
            </label>
            <input
              value={farmName}
              onChange={e => { setFarmName(e.target.value); setFarmNameError(false) }}
              placeholder="Например: КХ «Айгерим»"
              className="w-full h-11 px-3 rounded-xl text-sm outline-none transition-colors"
              style={{
                background: 'var(--bg-c)',
                border: `1px solid ${farmNameError ? 'var(--red)' : 'var(--bd)'}`,
                color: 'var(--fg)',
              }}
              onFocus={e => (e.target.style.borderColor = farmNameError ? 'var(--red)' : 'var(--blue)')}
              onBlur={e => (e.target.style.borderColor = farmNameError ? 'var(--red)' : 'var(--bd)')}
            />
          </div>
          <div>
            <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--fg2)' }}>Тип содержания</label>
            <Select value={shelterType || undefined} onValueChange={setShelterType}>
              <SelectTrigger className="h-11"><SelectValue placeholder="Не указано" /></SelectTrigger>
              <SelectContent>
                {SHELTER_TYPES.map(st => <SelectItem key={st.value} value={st.value}>{st.label}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <div>
            <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--fg2)' }}>Система отёлов</label>
            <Select value={calvingSystem || undefined} onValueChange={setCalvingSystem}>
              <SelectTrigger className="h-11"><SelectValue placeholder="Не указано" /></SelectTrigger>
              <SelectContent>
                {CALVING_SYSTEMS.map(cs => <SelectItem key={cs.value} value={cs.value}>{cs.label}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <button
            onClick={() => handleSaveFarm()}
            disabled={isSavingFarm}
            className="w-full h-11 rounded-xl text-sm font-semibold flex items-center justify-center gap-2 mt-2 transition-opacity disabled:opacity-40"
            style={{ background: 'var(--cta)', color: 'var(--cta-fg)' }}
          >
            {isSavingFarm && <Loader2 className="h-4 w-4 animate-spin" />}
            Создать ферму
          </button>
        </div>
      </div>
    )
  }

  // ── Main layout (farm exists) ─────────────────────────────────────────────────
  return (
    <div className="page">

      {/* ── HERO CARD ─────────────────────────────────────────────────────────── */}
      <div
        className="rounded-xl overflow-hidden border mb-5"
        style={{ background: 'var(--bg-c)', borderColor: 'var(--bd)', boxShadow: 'var(--sh-sm)' }}
      >
        {/* Brand band */}
        <div
          className="h-1.5"
          style={{ background: 'linear-gradient(90deg, var(--brand) 0%, var(--amber) 100%)' }}
        />

        <div className="p-5 pb-6">
          {/* Top row: avatar + name/tags */}
          <div className="flex items-start gap-4 mb-5">
            <div
              className="w-[52px] h-[52px] rounded-xl shrink-0 flex items-center justify-center text-lg font-bold border select-none"
              style={{ background: 'var(--bg-m)', color: 'var(--fg)', borderColor: 'var(--bd)' }}
            >
              {(farm.name || 'Ф').charAt(0).toUpperCase()}
            </div>

            <div className="flex-1 min-w-0">
              {/* Name + pencil + badge */}
              <div className="flex items-center gap-2 flex-wrap mb-2">
                <span className="text-lg font-bold tracking-tight" style={{ color: 'var(--fg)' }}>
                  {farm.name}
                </span>
                <button
                  onClick={openSheet}
                  title="Переименовать ферму"
                  className="w-6 h-6 rounded-md flex items-center justify-center border-0 bg-transparent cursor-pointer transition-colors shrink-0"
                  style={{ color: 'var(--fg3)' }}
                  onMouseEnter={e => { e.currentTarget.style.background = 'var(--bg-m)'; e.currentTarget.style.color = 'var(--fg2)' }}
                  onMouseLeave={e => { e.currentTarget.style.background = 'transparent'; e.currentTarget.style.color = 'var(--fg3)' }}
                >
                  <Pencil className="h-3 w-3" />
                </button>
                <StatusBadge status={membershipBadgeStatus} label={membershipLabel} />
              </div>

              {/* Tags: shelter + calving */}
              <div className="flex flex-wrap gap-1.5">
                {shelterLabel && (
                  <span
                    className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs border"
                    style={{ borderColor: 'var(--bd)', color: 'var(--fg2)', background: 'var(--bg)' }}
                  >
                    <Home className="h-3 w-3 shrink-0" />
                    {shelterLabel}
                  </span>
                )}
                {calvingLabel && (
                  <span
                    className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs border"
                    style={{ borderColor: 'var(--bd)', color: 'var(--fg2)', background: 'var(--bg)' }}
                  >
                    <Calendar className="h-3 w-3 shrink-0" />
                    {calvingLabel}
                  </span>
                )}
              </div>
            </div>
          </div>

          {/* KPI row */}
          <div
            className="grid grid-cols-3 gap-px rounded-xl overflow-hidden border"
            style={{ borderColor: 'var(--bd)', background: 'var(--bd)' }}
          >
            {[
              { label: 'Всего голов',   value: totalHeads > 0 ? String(totalHeads) : '—', sub: 'гол. на ферме' },
              { label: 'Групп',         value: groupCount > 0 ? String(groupCount) : '—', sub: 'производственные' },
              { label: 'Членство',      value: membershipLabel,                            sub: 'статус в ассоциации', small: true },
            ].map(kpi => (
              <div key={kpi.label} className="px-4 py-3.5 flex flex-col gap-0.5" style={{ background: 'var(--bg-c)' }}>
                <span
                  className="text-[11px] font-medium uppercase tracking-wider"
                  style={{ color: 'var(--fg3)' }}
                >
                  {kpi.label}
                </span>
                <span
                  className="font-bold tracking-tight leading-none"
                  style={{ color: 'var(--fg)', fontSize: kpi.small ? '15px' : '20px' }}
                >
                  {kpi.value}
                </span>
                <span className="text-xs" style={{ color: 'var(--fg2)' }}>{kpi.sub}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* ── CONTENT GRID ──────────────────────────────────────────────────────── */}
      <div className="grid gap-4 items-start" style={{ gridTemplateColumns: '1fr 420px' }}>

        {/* LEFT: О ферме card ──────────────────────────────────────────────────── */}
        <div className="flex flex-col gap-4">
          <div
            className="rounded-xl border overflow-hidden"
            style={{ background: 'var(--bg-c)', borderColor: 'var(--bd)', boxShadow: 'var(--sh-sm)' }}
          >
            {/* Card header */}
            <div className="px-5 pt-4 pb-0 flex items-center justify-between">
              <span
                className="text-[11px] font-semibold uppercase tracking-wider"
                style={{ color: 'var(--fg3)' }}
              >
                О ферме
              </span>
              <button
                onClick={openSheet}
                className="inline-flex items-center gap-1.5 h-[26px] px-2.5 rounded-md text-[11px] font-semibold border cursor-pointer transition-colors"
                style={{ background: 'var(--blue-m)', borderColor: 'rgba(69,113,184,0.22)', color: 'var(--blue)' }}
                onMouseEnter={e => (e.currentTarget.style.background = 'rgba(69,113,184,0.13)')}
                onMouseLeave={e => (e.currentTarget.style.background = 'var(--blue-m)')}
              >
                <Pencil className="h-2.5 w-2.5" />
                Редактировать
              </button>
            </div>

            {/* Char-list */}
            <div className="px-3 py-2">
              <CharRow icon={<Home className="h-3.5 w-3.5" />}     label="Тип содержания" value={shelterLabel} />
              <CharRow icon={<Calendar className="h-3.5 w-3.5" />} label="Система отёлов"  value={calvingLabel} />
            </div>

            {/* Divider */}
            <div className="mx-5 my-1" style={{ height: 1, background: 'var(--bd-s)' }} />

            {/* Activities section */}
            <div className="px-5 pt-3 pb-5">
              <p
                className="text-[11px] font-semibold uppercase tracking-wider mb-2.5"
                style={{ color: 'var(--fg3)' }}
              >
                Виды деятельности
              </p>
              <div className="flex flex-wrap gap-2">
                {ACTIVITY_TYPES.map(at => {
                  const selected = activities.includes(at.id)
                  return (
                    <button
                      key={at.id}
                      onClick={() => handleActivityToggle(at.id)}
                      className="px-3 py-1.5 rounded-full text-xs border cursor-pointer transition-all"
                      style={{
                        background:   selected ? 'var(--blue-m)' : 'transparent',
                        borderColor:  selected ? 'rgba(69,113,184,0.25)' : 'var(--bd)',
                        color:        selected ? 'var(--blue)' : 'var(--fg2)',
                        fontWeight:   selected ? 600 : 400,
                      }}
                    >
                      {at.label}
                    </button>
                  )
                })}
              </div>
              {activities.length === 0 && (
                <p className="text-[11px] mt-2" style={{ color: 'var(--fg3)' }}>
                  Нажмите на категорию чтобы выбрать
                </p>
              )}
            </div>
          </div>

          {/* Health restriction warning */}
          {hasRestrictions && (
            <div
              className="flex items-start gap-3 p-4 rounded-xl"
              style={{ background: 'rgba(192,57,43,0.07)', border: '1px solid rgba(192,57,43,0.14)' }}
            >
              <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" style={{ color: 'var(--red)' }} />
              <div>
                <p className="text-sm font-semibold" style={{ color: 'var(--red)' }}>Ограничение на продажу</p>
                {userContext!.health_restrictions.map(hr => (
                  <p key={hr.id} className="text-xs mt-0.5" style={{ color: 'var(--red)' }}>
                    {hr.reason} — до {new Date(hr.expires_at).toLocaleDateString('ru-RU')}
                  </p>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* RIGHT: Livestock + Disease ─────────────────────────────────────────── */}
        <div className="flex flex-col gap-4">

          {/* Livestock card */}
          <div
            className="rounded-xl border overflow-hidden"
            style={{ background: 'var(--bg-c)', borderColor: 'var(--bd)', boxShadow: 'var(--sh-sm)' }}
          >
            {/* Header */}
            <div
              className="flex items-center justify-between px-4 pt-3.5 pb-2.5 border-b"
              style={{ borderColor: 'var(--bd-s)' }}
            >
              <span
                className="text-[11px] font-semibold uppercase tracking-wider"
                style={{ color: 'var(--fg3)' }}
              >
                Поголовье
              </span>
              <button
                onClick={() => { setHerdForm(EMPTY_HERD_FORM); setShowHerdForm(true); setHerdErrors({}) }}
                className="inline-flex items-center gap-1 text-[12px] font-semibold px-2.5 py-1 rounded-md border cursor-pointer transition-colors"
                style={{ color: 'var(--blue)', borderColor: 'rgba(69,113,184,0.25)', background: 'var(--blue-m)' }}
                onMouseEnter={e => (e.currentTarget.style.background = 'rgba(69,113,184,0.13)')}
                onMouseLeave={e => (e.currentTarget.style.background = 'var(--blue-m)')}
              >
                <Plus className="h-2.5 w-2.5" strokeWidth={2.5} />
                Добавить
              </button>
            </div>

            {/* Total summary */}
            {totalHeads > 0 && (
              <div
                className="flex items-center justify-between px-4 py-3 border-b"
                style={{ borderColor: 'var(--bd-s)', background: 'var(--bg)' }}
              >
                <div>
                  <div
                    className="font-bold tracking-tight leading-none"
                    style={{ fontSize: 22, color: 'var(--fg)' }}
                  >
                    {totalHeads}{' '}
                    <span style={{ fontSize: 14, fontWeight: 500, color: 'var(--fg2)' }}>гол.</span>
                  </div>
                  <div className="text-[11px] mt-0.5" style={{ color: 'var(--fg3)' }}>всего на ферме</div>
                </div>
                <div className="text-right">
                  <div className="text-[11px]" style={{ color: 'var(--fg3)' }}>
                    <strong style={{ color: 'var(--fg2)', fontWeight: 600 }}>{groupCount}</strong>{' '}
                    {groupWord}
                  </div>
                  {avgWeight > 0 && (
                    <div className="text-[11px] mt-0.5" style={{ color: 'var(--fg3)' }}>
                      сред. вес{' '}
                      <strong style={{ color: 'var(--fg2)', fontWeight: 600 }}>{avgWeight} кг</strong>
                    </div>
                  )}
                </div>
              </div>
            )}

            {/* Group rows */}
            {farm.herd_groups && farm.herd_groups.length > 0 ? (
              farm.herd_groups.map((group, idx) => {
                const pct = totalHeads > 0 ? Math.round((group.head_count / totalHeads) * 100) : 0
                const isLast = idx === farm.herd_groups!.length - 1
                return (
                  <div
                    key={group.id}
                    onClick={() => editHerdGroup(group)}
                    className="flex items-center gap-2.5 px-4 py-3 cursor-pointer transition-colors"
                    style={{ borderBottom: isLast ? 'none' : '1px solid var(--bd-s)' }}
                    onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg)')}
                    onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
                  >
                    <div className="flex-1 min-w-0">
                      <div className="text-[13px] font-semibold mb-0.5" style={{ color: 'var(--fg)' }}>
                        {group.animal_category_name || group.animal_category_code}
                      </div>
                      <div className="text-[11px] mb-1.5" style={{ color: 'var(--fg3)' }}>
                        {group.breed_name || 'Порода не указана'}
                      </div>
                      <div
                        className="w-full rounded-full overflow-hidden"
                        style={{ height: 3, background: 'var(--bg-m)' }}
                      >
                        <div
                          className="h-full rounded-full"
                          style={{ width: `${pct}%`, background: 'var(--blue)' }}
                        />
                      </div>
                    </div>
                    <div className="text-right shrink-0">
                      <div
                        className="text-sm font-bold tabular-nums"
                        style={{ color: 'var(--fg)' }}
                      >
                        {group.head_count} гол.
                      </div>
                      {group.avg_weight_kg != null && (
                        <div className="text-[11px] mt-0.5" style={{ color: 'var(--fg3)' }}>
                          ~{group.avg_weight_kg} кг/гол.
                        </div>
                      )}
                    </div>
                    <ChevronRight className="h-3.5 w-3.5 shrink-0" style={{ color: 'var(--fg3)' }} />
                  </div>
                )
              })
            ) : (
              !showHerdForm && (
                <div className="py-8 text-center px-4">
                  <p className="text-sm" style={{ color: 'var(--fg3)' }}>Нет групп животных</p>
                  <button
                    onClick={() => { setHerdForm(EMPTY_HERD_FORM); setShowHerdForm(true) }}
                    className="mt-1.5 text-sm underline underline-offset-2"
                    style={{ color: 'var(--fg2)' }}
                  >
                    Добавить первую группу
                  </button>
                </div>
              )
            )}

            {/* Inline herd form */}
            {showHerdForm && (
              <div
                className="p-4 space-y-3 border-t"
                style={{ borderColor: 'var(--bd)' }}
              >
                <p className="text-xs font-semibold" style={{ color: 'var(--fg2)' }}>
                  {herdForm.id ? 'Редактировать группу' : 'Новая группа'}
                </p>

                <div>
                  <label className="text-xs mb-1.5 block" style={{ color: 'var(--fg2)' }}>Категория *</label>
                  <Select
                    value={herdForm.animal_category_code || undefined}
                    onValueChange={v => { setHerdForm(f => ({ ...f, animal_category_code: v })); if (herdErrors.category) setHerdErrors(e => ({ ...e, category: '' })) }}
                  >
                    <SelectTrigger
                      className="h-9"
                      style={{ borderColor: herdErrors.category ? 'var(--red)' : undefined }}
                    >
                      <SelectValue placeholder="Выберите категорию" />
                    </SelectTrigger>
                    <SelectContent>
                      {ANIMAL_CATEGORIES.map(c => <SelectItem key={c.code} value={c.code}>{c.name}</SelectItem>)}
                    </SelectContent>
                  </Select>
                  {herdErrors.category && <p className="text-xs mt-1" style={{ color: 'var(--red)' }}>{herdErrors.category}</p>}
                </div>

                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="text-xs mb-1.5 block" style={{ color: 'var(--fg2)' }}>Голов *</label>
                    <input
                      type="number" min="1"
                      value={herdForm.head_count}
                      onChange={e => { setHerdForm(f => ({ ...f, head_count: e.target.value })); if (herdErrors.head_count) setHerdErrors(e => ({ ...e, head_count: '' })) }}
                      placeholder="0"
                      className="w-full h-9 px-3 rounded-lg text-sm outline-none transition-colors [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                      style={{ background: 'var(--bg)', border: `1px solid ${herdErrors.head_count ? 'var(--red)' : 'var(--bd)'}`, color: 'var(--fg)' }}
                      onFocus={e => (e.target.style.borderColor = herdErrors.head_count ? 'var(--red)' : 'var(--blue)')}
                      onBlur={e => (e.target.style.borderColor = herdErrors.head_count ? 'var(--red)' : 'var(--bd)')}
                    />
                    {herdErrors.head_count && <p className="text-xs mt-1" style={{ color: 'var(--red)' }}>{herdErrors.head_count}</p>}
                  </div>
                  <div>
                    <label className="text-xs mb-1.5 block" style={{ color: 'var(--fg2)' }}>Ср. вес (кг)</label>
                    <input
                      type="number" min="1" max="2000"
                      value={herdForm.avg_weight_kg}
                      onChange={e => { setHerdForm(f => ({ ...f, avg_weight_kg: e.target.value })); if (herdErrors.avg_weight) setHerdErrors(e => ({ ...e, avg_weight: '' })) }}
                      placeholder="—"
                      className="w-full h-9 px-3 rounded-lg text-sm outline-none transition-colors [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                      style={{ background: 'var(--bg)', border: `1px solid ${herdErrors.avg_weight ? 'var(--red)' : 'var(--bd)'}`, color: 'var(--fg)' }}
                      onFocus={e => (e.target.style.borderColor = herdErrors.avg_weight ? 'var(--red)' : 'var(--blue)')}
                      onBlur={e => (e.target.style.borderColor = herdErrors.avg_weight ? 'var(--red)' : 'var(--bd)')}
                    />
                    {herdErrors.avg_weight && <p className="text-xs mt-1" style={{ color: 'var(--red)' }}>{herdErrors.avg_weight}</p>}
                  </div>
                </div>

                <div>
                  <label className="text-xs mb-1.5 block" style={{ color: 'var(--fg2)' }}>Порода</label>
                  <Select
                    value={herdForm.breed_id || undefined}
                    onValueChange={v => setHerdForm(f => ({ ...f, breed_id: v }))}
                  >
                    <SelectTrigger className="h-9"><SelectValue placeholder="Не указана" /></SelectTrigger>
                    <SelectContent>
                      {breedsDb.map(b => <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>)}
                    </SelectContent>
                  </Select>
                </div>

                <div className="flex gap-2 pt-1">
                  <button
                    onClick={handleSaveHerdGroup}
                    disabled={isSavingHerd}
                    className="flex-1 h-9 rounded-lg text-sm font-semibold flex items-center justify-center gap-2 transition-opacity disabled:opacity-40 cursor-pointer"
                    style={{ background: 'var(--cta)', color: 'var(--cta-fg)' }}
                  >
                    {isSavingHerd && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                    {herdForm.id ? 'Обновить' : 'Добавить'}
                  </button>
                  <button
                    onClick={() => { setShowHerdForm(false); setHerdForm(EMPTY_HERD_FORM); setHerdErrors({}) }}
                    className="h-9 px-3 text-sm rounded-lg border cursor-pointer transition-colors"
                    style={{ color: 'var(--fg2)', borderColor: 'var(--bd)', background: 'transparent' }}
                  >
                    Отмена
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Disease action card */}
          <div
            onClick={() => navigate('/cabinet-legacy/vet/new')}
            className="flex items-center gap-3 rounded-xl border px-4 py-3.5 cursor-pointer transition-colors"
            style={{ background: 'var(--bg-c)', borderColor: 'var(--bd)', boxShadow: 'var(--sh-sm)' }}
            onMouseEnter={e => {
              e.currentTarget.style.borderColor = 'rgba(192,57,43,0.4)'
              e.currentTarget.style.background = 'rgba(192,57,43,0.04)'
            }}
            onMouseLeave={e => {
              e.currentTarget.style.borderColor = 'var(--bd)'
              e.currentTarget.style.background = 'var(--bg-c)'
            }}
          >
            <div
              className="w-[34px] h-[34px] rounded-lg flex items-center justify-center shrink-0"
              style={{ background: 'rgba(192,57,43,0.08)', border: '1px solid rgba(192,57,43,0.18)', color: 'var(--red)' }}
            >
              <Activity className="h-4 w-4" />
            </div>
            <div className="flex-1">
              <div className="text-[13px] font-semibold" style={{ color: 'var(--red)' }}>
                Сообщить о болезни
              </div>
              <div className="text-[11px] mt-0.5" style={{ color: 'var(--fg3)' }}>
                Зарегистрировать ветеринарный случай
              </div>
            </div>
            <ChevronRight className="h-3.5 w-3.5 shrink-0" style={{ color: 'var(--fg3)' }} />
          </div>

        </div>
      </div>

      {/* ── EDIT SHEET ────────────────────────────────────────────────────────── */}
      {isSheetOpen && (
        <div
          className="fixed inset-0 z-50 flex items-stretch justify-end"
          style={{ background: 'rgba(0,0,0,0.45)' }}
          onClick={e => { if (e.target === e.currentTarget) closeSheet() }}
        >
          <div
            className="w-[460px] flex flex-col border-l"
            style={{
              background: 'var(--bg-c)',
              borderColor: 'var(--bd)',
              animation: 'shellPanelSlideIn 200ms var(--ease)',
            }}
          >
            {/* Sheet header */}
            <div
              className="flex items-center justify-between px-5 py-4 border-b shrink-0"
              style={{ borderColor: 'var(--bd)' }}
            >
              <div>
                <div className="text-sm font-bold" style={{ color: 'var(--fg)' }}>Редактировать ферму</div>
                <div className="text-xs mt-0.5" style={{ color: 'var(--fg2)' }}>
                  Название, тип содержания, система отёлов
                </div>
              </div>
              <button
                onClick={closeSheet}
                className="w-7 h-7 rounded-md flex items-center justify-center border-0 bg-transparent cursor-pointer transition-colors"
                style={{ color: 'var(--fg2)' }}
                onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg-m)')}
                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>

            {/* Sheet body */}
            <div className="flex-1 overflow-y-auto p-5 space-y-4">
              <div>
                <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--fg2)' }}>
                  Название фермы
                </label>
                <input
                  value={farmName}
                  onChange={e => { setFarmName(e.target.value); setFarmNameError(false) }}
                  placeholder="Например: КХ «Айгерим»"
                  className="w-full h-9 px-3 rounded-lg text-sm outline-none transition-colors"
                  style={{
                    background: 'var(--bg)',
                    border: `1px solid ${farmNameError ? 'var(--red)' : 'var(--bd)'}`,
                    color: 'var(--fg)',
                    fontFamily: 'inherit',
                  }}
                  onFocus={e => (e.target.style.borderColor = farmNameError ? 'var(--red)' : 'var(--blue)')}
                  onBlur={e => (e.target.style.borderColor = farmNameError ? 'var(--red)' : 'var(--bd)')}
                />
                {farmNameError && (
                  <p className="text-xs mt-1" style={{ color: 'var(--red)' }}>Введите название фермы</p>
                )}
              </div>

              <div>
                <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--fg2)' }}>
                  Тип содержания
                </label>
                <Select value={shelterType || undefined} onValueChange={setShelterType}>
                  <SelectTrigger className="h-9"><SelectValue placeholder="Не указано" /></SelectTrigger>
                  <SelectContent>
                    {SHELTER_TYPES.map(st => <SelectItem key={st.value} value={st.value}>{st.label}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>

              <div>
                <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--fg2)' }}>
                  Система отёлов
                </label>
                <Select value={calvingSystem || undefined} onValueChange={setCalvingSystem}>
                  <SelectTrigger className="h-9"><SelectValue placeholder="Не указано" /></SelectTrigger>
                  <SelectContent>
                    {CALVING_SYSTEMS.map(cs => <SelectItem key={cs.value} value={cs.value}>{cs.label}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
            </div>

            {/* Sheet footer */}
            <div
              className="px-5 py-3.5 border-t flex gap-2 shrink-0"
              style={{ borderColor: 'var(--bd)' }}
            >
              <button
                onClick={closeSheet}
                className="h-9 px-4 rounded-lg text-sm border cursor-pointer transition-colors"
                style={{ color: 'var(--fg2)', borderColor: 'var(--bd)', background: 'transparent' }}
                onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg-m)')}
                onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}
              >
                Отмена
              </button>
              <button
                onClick={() => handleSaveFarm(closeSheet)}
                disabled={isSavingFarm}
                className="flex-1 h-9 rounded-lg text-sm font-semibold flex items-center justify-center gap-2 cursor-pointer disabled:opacity-40 transition-opacity"
                style={{ background: 'var(--cta)', color: 'var(--cta-fg)' }}
              >
                {isSavingFarm && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                Сохранить изменения
              </button>
            </div>
          </div>
        </div>
      )}

    </div>
  )
}

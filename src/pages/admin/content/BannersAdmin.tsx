import { useState } from 'react'
import { Megaphone, Plus, Pencil } from 'lucide-react'
import { AdminPageHeader } from '@/components/admin/ui/AdminPageHeader'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import {
  Select, SelectTrigger, SelectValue, SelectContent, SelectItem,
} from '@/components/ui/select'
import {
  Table, TableHeader, TableRow, TableHead, TableBody, TableCell,
} from '@/components/ui/table'
import {
  useAdminHomeBanners, useSaveHomeBanner, useToggleHomeBanner,
  type HomeBanner, type SaveHomeBannerInput,
} from '@/hooks/useAdminHomeBanners'

type AppKey = 'farmer' | 'mpk'

const INTERNAL_TARGETS = [
  'open_prices', 'open_market', 'join_membership', 'pay_membership',
  'open_course', 'open_tsp', 'open_offers',
] as const

const TONES = ['neutral', 'green', 'gold'] as const
const VARIANTS = ['all', 'season', 'campaign', 'join'] as const

const EMPTY: SaveHomeBannerInput = {
  p_id: null, p_app: 'farmer', p_title: '', p_subtitle: '', p_kicker: '',
  p_image_path: '', p_icon: '', p_tone: 'neutral', p_action_type: 'none',
  p_action_target: '', p_membership_variant: 'all', p_sort_order: 0,
  p_active_from: '', p_active_until: '', p_is_active: true,
}

function toForm(b: HomeBanner): SaveHomeBannerInput {
  return {
    p_id: b.id, p_app: b.app, p_title: b.title, p_subtitle: b.subtitle ?? '',
    p_kicker: b.kicker ?? '', p_image_path: b.image_path ?? '', p_icon: b.icon ?? '',
    p_tone: b.tone, p_action_type: b.action_type, p_action_target: b.action_target ?? '',
    p_membership_variant: b.membership_variant, p_sort_order: b.sort_order,
    p_active_from: b.active_from?.slice(0, 16) ?? '', p_active_until: b.active_until?.slice(0, 16) ?? '',
    p_is_active: b.is_active,
  }
}

function BannerPreview({ f }: { f: SaveHomeBannerInput }) {
  const toneBg: Record<string, string> = {
    gold: 'linear-gradient(135deg,#8a6d3b,#c9a227)',
    green: 'linear-gradient(135deg,#2f5e3f,#4a8c5f)',
    neutral: 'linear-gradient(135deg,#3a3f47,#5a6270)',
  }
  return (
    <div
      className="rounded-xl p-4 text-white min-h-[96px] flex flex-col justify-end"
      style={{ background: toneBg[f.p_tone ?? 'neutral'] }}
    >
      {f.p_kicker && <div className="text-[11px] uppercase tracking-wide opacity-80">{f.p_kicker}</div>}
      <div className="text-base font-semibold leading-tight">{f.p_title || 'Заголовок баннера'}</div>
      {f.p_subtitle && <div className="text-sm opacity-90 mt-1">{f.p_subtitle}</div>}
    </div>
  )
}

function BannerForm({
  app, initial, onClose,
}: { app: AppKey; initial?: HomeBanner; onClose: () => void }) {
  const [f, setF] = useState<SaveHomeBannerInput>(
    initial ? toForm(initial) : { ...EMPTY, p_app: app },
  )
  const save = useSaveHomeBanner()
  const set = <K extends keyof SaveHomeBannerInput>(k: K, v: SaveHomeBannerInput[K]) =>
    setF((prev) => ({ ...prev, [k]: v }))

  const urlInvalid = f.p_action_type === 'external'
    && !!f.p_action_target && !/^https:\/\//.test(f.p_action_target)
  const canSave = !!f.p_title.trim()
    && (f.p_action_type === 'none' || !!f.p_action_target)
    && !urlInvalid

  const submit = () => {
    // none → target пуст; пустые окна/строки → null
    const payload: SaveHomeBannerInput = {
      ...f,
      p_action_target: f.p_action_type === 'none' ? null : (f.p_action_target || null),
      p_subtitle: f.p_subtitle || null,
      p_kicker: f.p_kicker || null,
      p_image_path: f.p_image_path || null,
      p_icon: f.p_icon || null,
      p_active_from: f.p_active_from || null,
      p_active_until: f.p_active_until || null,
      p_sort_order: Number(f.p_sort_order) || 0,
    }
    save.mutate(payload, { onSuccess: onClose })
  }

  return (
    <div className="grid gap-4 md:grid-cols-2">
      <div className="grid gap-3">
        <div className="grid gap-1.5">
          <Label>Верхний лейбл (kicker)</Label>
          <Input value={f.p_kicker ?? ''} onChange={(e) => set('p_kicker', e.target.value)} placeholder="ЦЕНЫ TURAN" />
        </div>
        <div className="grid gap-1.5">
          <Label>Заголовок *</Label>
          <Input value={f.p_title} onChange={(e) => set('p_title', e.target.value)} placeholder="Справочные цены" />
        </div>
        <div className="grid gap-1.5">
          <Label>Подпись / лейбл CTA</Label>
          <Input value={f.p_subtitle ?? ''} onChange={(e) => set('p_subtitle', e.target.value)} placeholder="Открыть справочные цены" />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="grid gap-1.5">
            <Label>Тон</Label>
            <Select value={f.p_tone} onValueChange={(v) => set('p_tone', v)}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>{TONES.map((t) => <SelectItem key={t} value={t}>{t}</SelectItem>)}</SelectContent>
            </Select>
          </div>
          <div className="grid gap-1.5">
            <Label>Вариант членства</Label>
            <Select value={f.p_membership_variant} onValueChange={(v) => set('p_membership_variant', v)}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>{VARIANTS.map((v) => <SelectItem key={v} value={v}>{v}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        </div>
        <div className="grid gap-1.5">
          <Label>Картинка (asset-ключ или https-URL)</Label>
          <Input value={f.p_image_path ?? ''} onChange={(e) => set('p_image_path', e.target.value)} placeholder="banner-prices" />
        </div>
      </div>

      <div className="grid gap-3">
        <div className="grid gap-1.5">
          <Label>Тип действия</Label>
          <Select value={f.p_action_type} onValueChange={(v) => set('p_action_type', v)}>
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">нет действия</SelectItem>
              <SelectItem value="internal">внутреннее действие</SelectItem>
              <SelectItem value="external">внешняя ссылка</SelectItem>
            </SelectContent>
          </Select>
        </div>
        {f.p_action_type === 'internal' && (
          <div className="grid gap-1.5">
            <Label>Куда ведёт (внутри приложения)</Label>
            <Select value={f.p_action_target ?? ''} onValueChange={(v) => set('p_action_target', v)}>
              <SelectTrigger><SelectValue placeholder="выберите цель" /></SelectTrigger>
              <SelectContent>{INTERNAL_TARGETS.map((t) => <SelectItem key={t} value={t}>{t}</SelectItem>)}</SelectContent>
            </Select>
          </div>
        )}
        {f.p_action_type === 'external' && (
          <div className="grid gap-1.5">
            <Label>Внешняя ссылка (https://)</Label>
            <Input value={f.p_action_target ?? ''} onChange={(e) => set('p_action_target', e.target.value)} placeholder="https://turanstandard.kz/..." />
            {urlInvalid && <span className="text-xs text-destructive">Ссылка должна начинаться с https://</span>}
          </div>
        )}
        <div className="grid grid-cols-2 gap-3">
          <div className="grid gap-1.5">
            <Label>Активен с</Label>
            <Input type="datetime-local" value={f.p_active_from ?? ''} onChange={(e) => set('p_active_from', e.target.value)} />
          </div>
          <div className="grid gap-1.5">
            <Label>Активен до</Label>
            <Input type="datetime-local" value={f.p_active_until ?? ''} onChange={(e) => set('p_active_until', e.target.value)} />
          </div>
        </div>
        <div className="grid grid-cols-2 gap-3 items-end">
          <div className="grid gap-1.5">
            <Label>Порядок</Label>
            <Input type="number" value={f.p_sort_order ?? 0} onChange={(e) => set('p_sort_order', Number(e.target.value))} />
          </div>
          <div className="flex items-center gap-2 pb-2">
            <Switch checked={!!f.p_is_active} onCheckedChange={(v) => set('p_is_active', v)} />
            <Label>Активен</Label>
          </div>
        </div>
        <div className="grid gap-1.5">
          <Label>Превью</Label>
          <BannerPreview f={f} />
        </div>
      </div>

      <DialogFooter className="md:col-span-2">
        <Button variant="outline" onClick={onClose}>Отмена</Button>
        <Button onClick={submit} disabled={!canSave || save.isPending}>
          {save.isPending ? 'Сохранение…' : 'Сохранить'}
        </Button>
      </DialogFooter>
    </div>
  )
}

function BannerTable({ app }: { app: AppKey }) {
  const { data: banners = [], isLoading } = useAdminHomeBanners(app)
  const toggle = useToggleHomeBanner()
  const [editing, setEditing] = useState<HomeBanner | 'new' | null>(null)

  const rows = banners.filter((b) => b.app === app)

  return (
    <>
      <div className="flex justify-end mb-3">
        <Button size="sm" onClick={() => setEditing('new')}>
          <Plus className="w-4 h-4 mr-1" /> Новый баннер
        </Button>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground py-8 text-center">Загрузка…</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground py-8 text-center">Баннеров пока нет</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-12">#</TableHead>
              <TableHead>Заголовок</TableHead>
              <TableHead>Действие</TableHead>
              <TableHead>Вариант</TableHead>
              <TableHead className="w-24">Активен</TableHead>
              <TableHead className="w-16" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((b) => (
              <TableRow key={b.id}>
                <TableCell className="text-muted-foreground">{b.sort_order}</TableCell>
                <TableCell>
                  <div className="font-medium">{b.title}</div>
                  {b.kicker && <div className="text-xs text-muted-foreground">{b.kicker}</div>}
                </TableCell>
                <TableCell className="text-sm">
                  {b.action_type === 'none' ? '—' : `${b.action_type}: ${b.action_target}`}
                </TableCell>
                <TableCell className="text-sm">{b.membership_variant}</TableCell>
                <TableCell>
                  <Switch
                    checked={b.is_active}
                    onCheckedChange={(v) => toggle.mutate({ p_id: b.id, p_is_active: v })}
                  />
                </TableCell>
                <TableCell>
                  <Button variant="ghost" size="icon" onClick={() => setEditing(b)}>
                    <Pencil className="w-4 h-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      <Dialog open={editing !== null} onOpenChange={(o) => !o && setEditing(null)}>
        <DialogContent className="max-w-3xl">
          <DialogHeader>
            <DialogTitle>{editing === 'new' ? 'Новый баннер' : 'Редактирование баннера'}</DialogTitle>
          </DialogHeader>
          {editing !== null && (
            <BannerForm
              app={app}
              initial={editing === 'new' ? undefined : editing}
              onClose={() => setEditing(null)}
            />
          )}
        </DialogContent>
      </Dialog>
    </>
  )
}

export default function BannersAdmin() {
  const [app, setApp] = useState<AppKey>('farmer')

  return (
    <div className="max-w-6xl mx-auto">
      <AdminPageHeader title="Контент приложений — баннеры" />
      <p className="text-sm text-muted-foreground mb-4 flex items-center gap-1.5">
        <Megaphone className="w-4 h-4" />
        Промо-баннеры на Главной приложений «Фермер» и «МПК». Меняются без деплоя.
      </p>

      <Tabs value={app} onValueChange={(v) => setApp(v as AppKey)}>
        <TabsList>
          <TabsTrigger value="farmer">Фермер</TabsTrigger>
          <TabsTrigger value="mpk">МПК</TabsTrigger>
        </TabsList>
        <TabsContent value="farmer" className="mt-4">
          <BannerTable app="farmer" />
        </TabsContent>
        <TabsContent value="mpk" className="mt-4">
          <BannerTable app="mpk" />
        </TabsContent>
      </Tabs>
    </div>
  )
}

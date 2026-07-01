import { useState } from 'react'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { Switch } from '@/components/ui/switch'
import { Select, SelectTrigger, SelectValue, SelectContent, SelectItem } from '@/components/ui/select'
import { toast } from 'sonner'
import { useUpdateOrg } from '@/hooks/admin/useUpdateOrg'
import type { AdminOrg } from '@/hooks/admin/useAdminOrgs'
import { formatPhoneKz } from '@/lib/phone'
import { REGIONS, DISTRICTS } from '@/pages/registration/constants'
import { OrgDocumentsPanel } from './OrgDocumentsPanel'

interface Props {
  org: AdminOrg | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function OrgEditDialog({ org, open, onOpenChange }: Props) {
  const update = useUpdateOrg()

  const [legalName, setLegalName] = useState('')
  const [binIin, setBinIin] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [address, setAddress] = useState('')
  const [isActive, setIsActive] = useState(true)
  const [regionId, setRegionId] = useState<string>('')
  const [districtId, setDistrictId] = useState<string>('')
  const districtOptions = regionId ? DISTRICTS[regionId] ?? [] : []

  // Синхронизируем форму при открытии новой организации
  const [loadedId, setLoadedId] = useState<string | null>(null)
  if (org && org.id !== loadedId) {
    setLoadedId(org.id)
    setLegalName(org.legal_name ?? '')
    setBinIin(org.bin_iin ?? '')
    setPhone(org.phone ? formatPhoneKz(org.phone) : '')
    setEmail(org.email ?? '')
    setAddress(org.address_text ?? '')
    setIsActive(org.is_active)
    setRegionId(org.region_id ?? '')
    setDistrictId(org.district_id ?? '')
  }

  if (!org) return null

  async function handleSave() {
    if (!legalName.trim()) return toast.error('Укажите название')
    await update.mutateAsync({
      orgId: org!.id,
      legalName,
      binIin,
      phone,
      email,
      address,
      isActive,
      regionId: regionId || null,
      districtId: districtId || null,
    })
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Редактирование организации</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="oe-name">Название *</Label>
            <Input id="oe-name" value={legalName} onChange={(e) => setLegalName(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="oe-bin">БИН/ИИН</Label>
              <Input id="oe-bin" value={binIin} onChange={(e) => setBinIin(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="oe-phone">Телефон</Label>
              <Input id="oe-phone" inputMode="tel" value={phone} onChange={(e) => setPhone(formatPhoneKz(e.target.value))} placeholder="+7 771 085 6566" />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3 items-end">
            <div className="space-y-1.5">
              <Label htmlFor="oe-email">Email</Label>
              <Input id="oe-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            <div className="flex items-center gap-2 pb-2">
              <Switch id="oe-active" checked={isActive} onCheckedChange={setIsActive} />
              <Label htmlFor="oe-active">Активна</Label>
            </div>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="oe-address">Адрес</Label>
            <Input id="oe-address" value={address} onChange={(e) => setAddress(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Область</Label>
              <Select value={regionId} onValueChange={(v) => { setRegionId(v); setDistrictId('') }}>
                <SelectTrigger><SelectValue placeholder="Выберите область" /></SelectTrigger>
                <SelectContent>
                  {REGIONS.map((r) => (
                    <SelectItem key={r.id} value={r.id}>{r.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label>Район</Label>
              <Select value={districtId} onValueChange={setDistrictId} disabled={districtOptions.length === 0}>
                <SelectTrigger>
                  <SelectValue placeholder={regionId ? 'Выберите район' : 'Сначала область'} />
                </SelectTrigger>
                <SelectContent>
                  {districtOptions.map((d) => (
                    <SelectItem key={d.value} value={d.value}>{d.label}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            Новые партии фермеров этого хозяйства будут публиковаться с этой области. Район — адресная метка.
          </p>

          <div className="border-t pt-4">
            <OrgDocumentsPanel orgId={org.id} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Отмена</Button>
          <Button onClick={handleSave} disabled={update.isPending}>
            {update.isPending ? 'Сохранение…' : 'Сохранить'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

import { useState } from 'react'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { Select, SelectTrigger, SelectValue, SelectContent, SelectItem } from '@/components/ui/select'
import { toast } from 'sonner'
import { useCreateOrg, type CreateOrgInput } from '@/hooks/admin/useCreateOrg'
import { formatPhoneKz } from '@/lib/phone'
import { REGIONS } from '@/pages/registration/constants'

interface Props {
  open: boolean
  onOpenChange: (open: boolean) => void
}

type OrgType = CreateOrgInput['orgType']

const ORG_TYPE_LABEL: Record<OrgType, string> = {
  farmer: 'Фермер',
  mpk: 'МПК',
  supplier: 'Поставщик',
  consultant: 'Консультант',
  other: 'Другое',
}

export function OrgCreateDialog({ open, onOpenChange }: Props) {
  const create = useCreateOrg()
  const [legalName, setLegalName] = useState('')
  const [orgType, setOrgType] = useState<OrgType>('farmer')
  const [binIin, setBinIin] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [address, setAddress] = useState('')
  const [regionId, setRegionId] = useState('')

  function reset() {
    setLegalName(''); setOrgType('farmer'); setBinIin(''); setPhone(''); setEmail(''); setAddress(''); setRegionId('')
  }

  async function handleCreate() {
    if (!legalName.trim()) return toast.error('Укажите название')
    await create.mutateAsync({ legalName, orgType, binIin, phone, email, address, regionId: regionId || null })
    reset()
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) reset(); onOpenChange(o) }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Новая организация</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="org-name">Название *</Label>
            <Input id="org-name" value={legalName} onChange={(e) => setLegalName(e.target.value)} placeholder="напр. КХ Жайлау" />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Тип</Label>
              <Select value={orgType} onValueChange={(v) => setOrgType(v as OrgType)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {(Object.keys(ORG_TYPE_LABEL) as OrgType[]).map((t) => (
                    <SelectItem key={t} value={t}>{ORG_TYPE_LABEL[t]}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="org-bin">БИН/ИИН</Label>
              <Input id="org-bin" value={binIin} onChange={(e) => setBinIin(e.target.value)} />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="org-phone">Телефон</Label>
              <Input id="org-phone" inputMode="tel" value={phone} onChange={(e) => setPhone(formatPhoneKz(e.target.value))} placeholder="+7 771 085 6566" />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="org-email">Email</Label>
              <Input id="org-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="org-address">Адрес</Label>
            <Input id="org-address" value={address} onChange={(e) => setAddress(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label>Область / регион</Label>
            <Select value={regionId} onValueChange={setRegionId}>
              <SelectTrigger><SelectValue placeholder="Выберите область" /></SelectTrigger>
              <SelectContent>
                {REGIONS.map((r) => (
                  <SelectItem key={r.id} value={r.id}>{r.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Отмена</Button>
          <Button onClick={handleCreate} disabled={create.isPending}>
            {create.isPending ? 'Создание…' : 'Создать'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

import { useState } from 'react'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { Select, SelectTrigger, SelectValue, SelectContent, SelectItem } from '@/components/ui/select'
import { toast } from 'sonner'
import { useCreateUser } from '@/hooks/admin/useCreateUser'
import { useAdminOrgs } from '@/hooks/admin/useAdminOrgs'

interface Props {
  open: boolean
  onOpenChange: (open: boolean) => void
}

type Role = 'owner' | 'manager' | 'employee' | 'viewer'

const ROLE_LABEL: Record<Role, string> = {
  owner: 'Владелец',
  manager: 'Менеджер',
  employee: 'Сотрудник',
  viewer: 'Наблюдатель',
}

export function UserCreateDialog({ open, onOpenChange }: Props) {
  const create = useCreateUser()
  const { data: orgs, isLoading: orgsLoading } = useAdminOrgs('')
  const [fullName, setFullName] = useState('')
  const [phone, setPhone] = useState('')
  const [pin, setPin] = useState('')
  const [organizationId, setOrganizationId] = useState('')
  const [role, setRole] = useState<Role>('owner')
  const [email, setEmail] = useState('')
  const [language, setLanguage] = useState('ru')

  function reset() {
    setFullName(''); setPhone(''); setPin(''); setOrganizationId('')
    setRole('owner'); setEmail(''); setLanguage('ru')
  }

  async function handleCreate() {
    if (!phone.trim()) return toast.error('Укажите телефон')
    if (!/^\d{6}$/.test(pin)) return toast.error('ПИН-код — ровно 6 цифр')
    if (!organizationId) return toast.error('Выберите организацию')
    await create.mutateAsync({ phone, pin, organizationId, role, fullName, email, language })
    reset()
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) reset(); onOpenChange(o) }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Новый пользователь</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="new-name">Имя</Label>
            <Input id="new-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="new-phone">Телефон *</Label>
              <Input id="new-phone" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="77001234567" />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="new-pin">ПИН-код (6 цифр) *</Label>
              <Input
                id="new-pin"
                inputMode="numeric"
                maxLength={6}
                value={pin}
                onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 6))}
                placeholder="••••••"
              />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label>Организация *</Label>
              <Select value={organizationId} onValueChange={setOrganizationId} disabled={orgsLoading}>
                <SelectTrigger>
                  <SelectValue placeholder={orgsLoading ? 'Загрузка…' : 'Выберите организацию'} />
                </SelectTrigger>
                <SelectContent>
                  {(orgs ?? []).map((o) => (
                    <SelectItem key={o.id} value={o.id}>{o.legal_name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-1.5">
              <Label>Роль</Label>
              <Select value={role} onValueChange={(v) => setRole(v as Role)}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {(Object.keys(ROLE_LABEL) as Role[]).map((r) => (
                    <SelectItem key={r} value={r}>{ROLE_LABEL[r]}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="new-email">Email (необяз.)</Label>
              <Input id="new-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label>Язык</Label>
              <Select value={language} onValueChange={setLanguage}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="ru">Русский</SelectItem>
                  <SelectItem value="kk">Қазақша</SelectItem>
                  <SelectItem value="en">English</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            Пользователь войдёт по телефону и ПИН-коду и будет привязан к выбранной организации.
          </p>
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

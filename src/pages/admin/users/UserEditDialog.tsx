import { useState } from 'react'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { Switch } from '@/components/ui/switch'
import { Avatar, AvatarImage, AvatarFallback } from '@/components/ui/avatar'
import { Select, SelectTrigger, SelectValue, SelectContent, SelectItem } from '@/components/ui/select'
import { Upload, X } from 'lucide-react'
import { toast } from 'sonner'
import { useUpdateUser } from '@/hooks/admin/useUpdateUser'
import { useUploadAvatar } from '@/hooks/admin/useUploadAvatar'
import type { AdminUser } from '@/hooks/admin/useAdminUsers'

const MAX_AVATAR = 5 * 1024 * 1024

interface Props {
  user: AdminUser | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function UserEditDialog({ user, open, onOpenChange }: Props) {
  const update = useUpdateUser()
  const uploadAvatar = useUploadAvatar()

  const [fullName, setFullName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [language, setLanguage] = useState('ru')
  const [isActive, setIsActive] = useState(true)
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null)

  // Синхронизируем форму при открытии нового пользователя
  const [loadedId, setLoadedId] = useState<string | null>(null)
  if (user && user.user_id !== loadedId) {
    setLoadedId(user.user_id)
    setFullName(user.full_name ?? '')
    setPhone(user.phone ?? '')
    setEmail(user.email ?? '')
    setLanguage(user.preferred_language ?? 'ru')
    setIsActive(user.is_active)
    setAvatarUrl(user.avatar_url)
  }

  if (!user) return null

  async function handleAvatarFile(file: File) {
    if (!file.type.startsWith('image/')) return toast.error('Только изображения')
    if (file.size > MAX_AVATAR) return toast.error('Файл не больше 5 МБ')
    try {
      const url = await uploadAvatar.mutateAsync({ userId: user!.user_id, file })
      setAvatarUrl(url)
    } catch {
      toast.error('Ошибка загрузки аватара')
    }
  }

  async function handleSave() {
    await update.mutateAsync({
      userId: user!.user_id,
      fullName,
      phone,
      email,
      language,
      isActive,
      avatarUrl,
    })
    onOpenChange(false)
  }

  const initials = (fullName || email || '?').slice(0, 2).toUpperCase()

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Редактирование профиля</DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="flex items-center gap-4">
            <Avatar className="h-16 w-16">
              {avatarUrl ? <AvatarImage src={avatarUrl} alt={fullName} /> : null}
              <AvatarFallback>{initials}</AvatarFallback>
            </Avatar>
            <div className="flex gap-2">
              <label className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm border cursor-pointer hover:bg-accent">
                <Upload className="h-4 w-4" />
                {uploadAvatar.isPending ? 'Загрузка…' : 'Загрузить'}
                <input
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => { const f = e.target.files?.[0]; if (f) handleAvatarFile(f) }}
                />
              </label>
              {avatarUrl && (
                <Button type="button" variant="outline" size="sm" onClick={() => setAvatarUrl(null)}>
                  <X className="h-4 w-4 mr-1" /> Убрать
                </Button>
              )}
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="edit-name">Имя</Label>
            <Input id="edit-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="edit-phone">Телефон</Label>
              <Input id="edit-phone" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="+7700…" />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="edit-email">Email</Label>
              <Input id="edit-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-3 items-end">
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
            <div className="flex items-center gap-2 pb-2">
              <Switch id="edit-active" checked={isActive} onCheckedChange={setIsActive} />
              <Label htmlFor="edit-active">Активен</Label>
            </div>
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

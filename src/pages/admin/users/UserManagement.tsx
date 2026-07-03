import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Avatar, AvatarImage, AvatarFallback } from '@/components/ui/avatar'
import {
  AlertDialog, AlertDialogContent, AlertDialogHeader, AlertDialogFooter,
  AlertDialogTitle, AlertDialogDescription, AlertDialogAction, AlertDialogCancel,
} from '@/components/ui/alert-dialog'
import { Search, UserCog, UserPlus, Pencil, Trash2 } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { useAdminUsers, type AdminUser } from '@/hooks/admin/useAdminUsers'
import { useDeleteUser } from '@/hooks/admin/useDeleteUser'
import { UserEditDialog } from './UserEditDialog'
import { UserCreateDialog } from './UserCreateDialog'

const ORG_TYPE_LABEL: Record<string, string> = { farmer: 'Фермер', mpk: 'МПК' }

export function UserManagement() {
  useSetTopbar({ title: 'Пользователи', titleIcon: <UserCog size={15} /> })
  const { isAdmin, checking } = useAdminGuard()
  const [search, setSearch] = useState('')
  const { data: users, isLoading, error } = useAdminUsers(search)
  const deleteUser = useDeleteUser()

  const [editing, setEditing] = useState<AdminUser | null>(null)
  const [editOpen, setEditOpen] = useState(false)
  const [createOpen, setCreateOpen] = useState(false)
  const [toDelete, setToDelete] = useState<AdminUser | null>(null)

  if (checking) return <div className="page">Проверка доступа...</div>
  if (!isAdmin) return null

  function openEdit(u: AdminUser) {
    setEditing(u)
    setEditOpen(true)
  }

  async function confirmDelete() {
    if (!toDelete) return
    await deleteUser.mutateAsync(toDelete.user_id)
    setToDelete(null)
  }

  return (
    <div className="page space-y-6">
      <div className="flex items-center gap-3">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
          <Input
            className="pl-9"
            placeholder="Поиск по имени, телефону, email..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <Button onClick={() => setCreateOpen(true)}>
          <UserPlus className="h-4 w-4 mr-1.5" /> Создать
        </Button>
      </div>

      {error ? (
        <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
          Не удалось загрузить пользователей: {(error as Error).message}
          <div className="mt-1 text-xs text-destructive/80">
            Если ошибка про функцию <code>rpc_admin_list_farmer_mpk_users</code> — миграция ещё не применена в Supabase.
          </div>
        </div>
      ) : isLoading ? (
        <Skeleton className="h-48 w-full" />
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-muted-foreground">
                <th className="p-2">Пользователь</th>
                <th className="p-2">Телефон</th>
                <th className="p-2">Организация</th>
                <th className="p-2">Членство</th>
                <th className="p-2">Статус</th>
                <th className="p-2 text-right">Действия</th>
              </tr>
            </thead>
            <tbody>
              {(users ?? []).map((u) => (
                <tr key={u.user_id} className="border-b border-border/50">
                  <td className="p-2">
                    <div className="flex items-center gap-2.5">
                      <Avatar className="h-8 w-8">
                        {u.avatar_url ? <AvatarImage src={u.avatar_url} alt={u.full_name ?? ''} /> : null}
                        <AvatarFallback>{(u.full_name || u.email || '?').slice(0, 2).toUpperCase()}</AvatarFallback>
                      </Avatar>
                      <div>
                        <div className="font-medium">{u.full_name || '—'}</div>
                        <div className="text-xs text-muted-foreground">{u.email || '—'}</div>
                      </div>
                    </div>
                  </td>
                  <td className="p-2">{u.phone || '—'}</td>
                  <td className="p-2">
                    <div>{u.organization_name || '—'}</div>
                    <div className="flex gap-1 mt-0.5">
                      {(u.org_types ?? []).map((t) => (
                        <Badge key={t} variant="outline" className="text-[10px] px-1.5 py-0">
                          {ORG_TYPE_LABEL[t] ?? t}
                        </Badge>
                      ))}
                    </div>
                  </td>
                  <td className="p-2">
                    <Badge variant={u.membership_paid ? 'default' : 'outline'}>
                      {u.membership_paid ? 'Оплачено' : 'Не оплачено'}
                    </Badge>
                  </td>
                  <td className="p-2">
                    <Badge variant={u.is_active ? 'default' : 'outline'}>
                      {u.is_active ? 'Активен' : 'Неактивен'}
                    </Badge>
                  </td>
                  <td className="p-2">
                    <div className="flex justify-end gap-1">
                      <Button variant="ghost" size="sm" onClick={() => openEdit(u)} aria-label="Редактировать">
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setToDelete(u)}
                        aria-label="Удалить"
                        className="text-destructive hover:text-destructive"
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  </td>
                </tr>
              ))}
              {(users ?? []).length === 0 && (
                <tr>
                  <td colSpan={6} className="p-6 text-center text-muted-foreground">
                    Пользователи не найдены
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}

      <UserEditDialog user={editing} open={editOpen} onOpenChange={setEditOpen} />
      <UserCreateDialog open={createOpen} onOpenChange={setCreateOpen} />

      <AlertDialog open={!!toDelete} onOpenChange={(o) => !o && setToDelete(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Удалить пользователя?</AlertDialogTitle>
            <AlertDialogDescription>
              {toDelete?.full_name || toDelete?.email || 'Пользователь'} будет удалён безвозвратно
              вместе с учётной записью и связанными данными. Действие необратимо.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Отмена</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => { e.preventDefault(); confirmDelete() }}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              disabled={deleteUser.isPending}
            >
              {deleteUser.isPending ? 'Удаление…' : 'Удалить навсегда'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

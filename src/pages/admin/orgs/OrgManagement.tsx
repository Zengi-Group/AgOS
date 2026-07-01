import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useState } from 'react'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import {
  AlertDialog, AlertDialogContent, AlertDialogHeader, AlertDialogFooter,
  AlertDialogTitle, AlertDialogDescription, AlertDialogAction, AlertDialogCancel,
} from '@/components/ui/alert-dialog'
import { Building2, Search, Plus, Pencil, Trash2 } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { useAdminOrgs, type AdminOrg } from '@/hooks/admin/useAdminOrgs'
import { useDeleteOrg } from '@/hooks/admin/useDeleteOrg'
import { OrgCreateDialog } from './OrgCreateDialog'
import { OrgEditDialog } from './OrgEditDialog'

const ORG_TYPE_LABEL: Record<string, string> = {
  farmer: 'Фермер', mpk: 'МПК', supplier: 'Поставщик', consultant: 'Консультант', other: 'Другое',
}

export function OrgManagement() {
  useSetTopbar({ title: 'Организации', titleIcon: <Building2 size={15} /> })
  const { isAdmin, checking } = useAdminGuard()
  const [search, setSearch] = useState('')
  const { data: orgs, isLoading, error } = useAdminOrgs(search)
  const deleteOrg = useDeleteOrg()

  const [editing, setEditing] = useState<AdminOrg | null>(null)
  const [editOpen, setEditOpen] = useState(false)
  const [createOpen, setCreateOpen] = useState(false)
  const [toDelete, setToDelete] = useState<AdminOrg | null>(null)

  if (checking) return <div className="page">Проверка доступа...</div>
  if (!isAdmin) return null

  function openEdit(o: AdminOrg) {
    setEditing(o)
    setEditOpen(true)
  }

  async function confirmDelete() {
    if (!toDelete) return
    await deleteOrg.mutateAsync(toDelete.id)
    setToDelete(null)
  }

  return (
    <div className="page space-y-6">
      <div className="flex items-center gap-3">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
          <Input
            className="pl-9"
            placeholder="Поиск по названию, БИН/ИИН, телефону..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <Button onClick={() => setCreateOpen(true)}>
          <Plus className="h-4 w-4 mr-1.5" /> Создать
        </Button>
      </div>

      {error ? (
        <div className="rounded-md border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive">
          Не удалось загрузить организации: {(error as Error).message}
          <div className="mt-1 text-xs text-destructive/80">
            Если ошибка про функцию <code>rpc_admin_list_organizations</code> — миграция ещё не применена в Supabase.
          </div>
        </div>
      ) : isLoading ? (
        <Skeleton className="h-48 w-full" />
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-muted-foreground">
                <th className="p-2">Название</th>
                <th className="p-2">Тип</th>
                <th className="p-2">Область</th>
                <th className="p-2">БИН/ИИН</th>
                <th className="p-2">Телефон</th>
                <th className="p-2">Участников</th>
                <th className="p-2">Статус</th>
                <th className="p-2 text-right">Действия</th>
              </tr>
            </thead>
            <tbody>
              {(orgs ?? []).map((o) => (
                <tr key={o.id} className="border-b border-border/50">
                  <td className="p-2 font-medium">{o.legal_name}</td>
                  <td className="p-2">
                    <div className="flex gap-1">
                      {(o.org_types ?? []).map((t) => (
                        <Badge key={t} variant="outline" className="text-[10px] px-1.5 py-0">
                          {ORG_TYPE_LABEL[t] ?? t}
                        </Badge>
                      ))}
                    </div>
                  </td>
                  <td className="p-2">{o.region_name || '—'}</td>
                  <td className="p-2">{o.bin_iin || '—'}</td>
                  <td className="p-2">{o.phone || '—'}</td>
                  <td className="p-2">{o.member_count}</td>
                  <td className="p-2">
                    <Badge variant={o.is_active ? 'default' : 'outline'}>
                      {o.is_active ? 'Активна' : 'Неактивна'}
                    </Badge>
                  </td>
                  <td className="p-2">
                    <div className="flex justify-end gap-1">
                      <Button variant="ghost" size="sm" onClick={() => openEdit(o)} aria-label="Редактировать">
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setToDelete(o)}
                        aria-label="Удалить"
                        className="text-destructive hover:text-destructive"
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  </td>
                </tr>
              ))}
              {(orgs ?? []).length === 0 && (
                <tr>
                  <td colSpan={8} className="p-6 text-center text-muted-foreground">
                    Организации не найдены
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}

      <OrgCreateDialog open={createOpen} onOpenChange={setCreateOpen} />
      <OrgEditDialog org={editing} open={editOpen} onOpenChange={setEditOpen} />

      <AlertDialog open={!!toDelete} onOpenChange={(o) => !o && setToDelete(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Удалить организацию?</AlertDialogTitle>
            <AlertDialogDescription>
              «{toDelete?.legal_name}» будет удалена безвозвратно вместе с типами, членством,
              привязками пользователей и связанными данными. Действие необратимо.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Отмена</AlertDialogCancel>
            <AlertDialogAction
              onClick={(e) => { e.preventDefault(); confirmDelete() }}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              disabled={deleteOrg.isPending}
            >
              {deleteOrg.isPending ? 'Удаление…' : 'Удалить навсегда'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useState, useEffect } from 'react'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Search, UserCog } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { supabase } from '@/lib/supabase'

export function UserManagement() {
  useSetTopbar({ title: 'Пользователи', titleIcon: <UserCog size={15} /> })
  const { isAdmin, checking: adminChecking } = useAdminGuard()
  const [users, setUsers] = useState<any[]>([])
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    async function load() {
      setLoading(true)
      let q = supabase.from('users').select('id, full_name, phone, email, is_active, created_at').order('created_at', { ascending: false }).limit(100)
      if (search) q = q.or(`full_name.ilike.%${search}%,phone.ilike.%${search}%,email.ilike.%${search}%`)
      const { data: usersData } = await q
      // Признак «членство оплачено» = у организации пользователя есть membership с level выше
      // 'registered' (оплата поднимает registered→observer). Сопоставляем через
      // user_organization_roles (user ↔ org) и memberships (org ↔ level). Админ читает обе по RLS.
      const [{ data: roles }, { data: memberships }] = await Promise.all([
        supabase.from('user_organization_roles').select('user_id, organization_id'),
        supabase.from('memberships').select('organization_id, level'),
      ])
      const paidOrgs = new Set<string>()
      ;(memberships || []).forEach((m: any) => { if (m.level && m.level !== 'registered') paidOrgs.add(m.organization_id) })
      const paidUsers = new Set<string>()
      ;(roles || []).forEach((r: any) => { if (paidOrgs.has(r.organization_id)) paidUsers.add(r.user_id) })
      if (cancelled) return
      setUsers((usersData || []).map((u: any) => ({ ...u, membershipPaid: paidUsers.has(u.id) })))
      setLoading(false)
    }
    load()
    return () => { cancelled = true }
  }, [search])

  if (adminChecking) return <div className="page">Проверка доступа...</div>
  if (!isAdmin) return null

  return (
    <div className="page space-y-6">
      <div className="relative"><Search className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
        <Input className="pl-9" placeholder="Поиск по имени, телефону..." value={search} onChange={e => setSearch(e.target.value)} />
      </div>
      {loading ? <Skeleton className="h-48 w-full" /> : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="border-b text-left text-muted-foreground">
              <th className="p-2">Имя</th><th className="p-2">Телефон</th><th className="p-2">Email</th><th className="p-2">Членство</th><th className="p-2">Статус</th><th className="p-2">Дата</th>
            </tr></thead>
            <tbody>{users.map(u => (
              <tr key={u.id} className="border-b border-border/50">
                <td className="p-2 font-medium">{u.full_name || '—'}</td>
                <td className="p-2">{u.phone || '—'}</td>
                <td className="p-2 text-xs">{u.email}</td>
                <td className="p-2"><Badge variant={u.membershipPaid ? 'default' : 'outline'}>{u.membershipPaid ? 'Оплачено' : 'Не оплачено'}</Badge></td>
                <td className="p-2"><Badge variant={u.is_active ? 'default' : 'outline'}>{u.is_active ? 'Активен' : 'Неактивен'}</Badge></td>
                <td className="p-2 text-xs">{new Date(u.created_at).toLocaleDateString('ru-RU')}</td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
    </div>
  )
}

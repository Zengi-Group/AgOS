import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { readEdgeError } from './edgeError'

export interface CreateUserInput {
  email: string
  phone: string
  password: string
  fullName: string
  language: string
}

export function useCreateUser() {
  const qc = useQueryClient()
  return useMutation<void, Error, CreateUserInput>({
    mutationFn: async (input) => {
      const { data, error } = await supabase.functions.invoke('admin-create-user', {
        body: {
          email: input.email,
          phone: input.phone,
          password: input.password,
          full_name: input.fullName,
          preferred_language: input.language,
        },
      })
      if (error) throw new Error(await readEdgeError(error, 'Ошибка создания'))
      if (data?.error) throw new Error(data.error)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-users'] })
      toast.success('Пользователь создан')
    },
    onError: (err) => toast.error(err.message || 'Ошибка создания'),
  })
}

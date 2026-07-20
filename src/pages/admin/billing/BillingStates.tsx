/**
 * ARS-271 — shared loading/error/empty states for the billing admin screens.
 * B7 lesson: on a failed fetch show an explicit error + retry, NEVER an empty
 * list (which reads as "no data"). Applied uniformly across all billing screens.
 */
import { AlertCircle, Inbox } from 'lucide-react'
import { Button } from '@/components/ui/button'

export function BillingError({ onRetry, message }: { onRetry: () => void; message?: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-16 text-center border border-border/60 rounded-[8px] bg-background">
      <AlertCircle className="h-6 w-6 text-rose-500" />
      <div className="text-[13px]" style={{ color: 'var(--fg2)' }}>
        {message || 'Не удалось загрузить данные'}
      </div>
      <Button size="sm" variant="outline" onClick={onRetry} className="h-7 px-3 text-[12px]">
        Повторить
      </Button>
    </div>
  )
}

export function BillingEmpty({ message }: { message: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 py-16 text-center border border-border/60 rounded-[8px] bg-background">
      <Inbox className="h-6 w-6" style={{ color: 'var(--fg3)' }} />
      <div className="text-[13px]" style={{ color: 'var(--fg3)' }}>{message}</div>
    </div>
  )
}

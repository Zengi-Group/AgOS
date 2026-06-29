import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { FileText, Download, Trash2, Upload } from 'lucide-react'
import { toast } from 'sonner'
import { useAdminOrgDocs } from '@/hooks/admin/useAdminOrgDocs'

const MAX_DOC = 20 * 1024 * 1024 // 20 МБ

function prettySize(bytes: number | null): string {
  if (bytes == null) return ''
  if (bytes < 1024) return `${bytes} Б`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} КБ`
  return `${(bytes / 1024 / 1024).toFixed(1)} МБ`
}

interface Props {
  orgId: string | undefined
}

export function OrgDocumentsPanel({ orgId }: Props) {
  const { data: docs, isLoading, upload, remove, download } = useAdminOrgDocs(orgId)

  if (!orgId) {
    return <p className="text-xs text-muted-foreground">Документы доступны после сохранения организации.</p>
  }

  function handleFile(file: File) {
    if (file.size > MAX_DOC) return toast.error('Файл не больше 20 МБ')
    upload.mutate(file)
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium flex items-center gap-1.5">
          <FileText className="h-4 w-4 text-muted-foreground" /> Документы
        </span>
        <label className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md text-xs border cursor-pointer hover:bg-accent">
          <Upload className="h-3.5 w-3.5" />
          {upload.isPending ? 'Загрузка…' : 'Добавить'}
          <input
            type="file"
            className="hidden"
            onChange={(e) => { const f = e.target.files?.[0]; if (f) handleFile(f); e.target.value = '' }}
          />
        </label>
      </div>

      {isLoading ? (
        <Skeleton className="h-16 w-full" />
      ) : (docs ?? []).length === 0 ? (
        <p className="text-xs text-muted-foreground">Документов пока нет.</p>
      ) : (
        <ul className="space-y-1">
          {(docs ?? []).map((d) => (
            <li key={d.path} className="flex items-center justify-between gap-2 rounded-md border px-2.5 py-1.5 text-sm">
              <div className="min-w-0">
                <div className="truncate">{d.name}</div>
                {d.size != null && <div className="text-[11px] text-muted-foreground">{prettySize(d.size)}</div>}
              </div>
              <div className="flex shrink-0 gap-1">
                <Button type="button" variant="ghost" size="sm" onClick={() => download(d.path)} aria-label="Скачать">
                  <Download className="h-4 w-4" />
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="text-destructive hover:text-destructive"
                  onClick={() => remove.mutate(d.path)}
                  disabled={remove.isPending}
                  aria-label="Удалить"
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

import { useCallback, useState } from 'react';
import { Upload, X, Image as ImageIcon } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { Button } from '@/components/ui/button';
import { useUploadCoverImage } from '@/hooks/useUploadCoverImage';
import { toast } from 'sonner';

const MAX_SIZE = 5 * 1024 * 1024; // 5MB
const ACCEPT = 'image/jpeg,image/png,image/webp';

interface ImageUploadProps {
  value: string | null;
  onChange: (url: string | null) => void;
}

export default function ImageUpload({ value, onChange }: ImageUploadProps) {
  const [dragging, setDragging] = useState(false);
  const upload = useUploadCoverImage();

  const handleFile = useCallback(
    async (file: File) => {
      if (!file.type.match(/^image\/(jpeg|png|webp)$/)) {
        toast.error('Только JPEG, PNG или WebP');
        return;
      }
      if (file.size > MAX_SIZE) {
        toast.error('Файл не должен превышать 5 МБ');
        return;
      }
      try {
        const url = await upload.mutateAsync(file);
        onChange(url);
      } catch {
        toast.error('Ошибка загрузки изображения');
      }
    },
    [upload, onChange],
  );

  const onDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setDragging(false);
      const file = e.dataTransfer.files[0];
      if (file) handleFile(file);
    },
    [handleFile],
  );

  const onFileSelect = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      if (file) handleFile(file);
    },
    [handleFile],
  );

  if (value) {
    return (
      <div className="relative rounded-lg overflow-hidden" style={{ aspectRatio: '16/9' }}>
        <img
          src={value}
          alt="Обложка"
          className="w-full h-full object-cover"
        />
        <div className="absolute top-2 right-2 flex gap-1">
          <label
            className="inline-flex items-center px-3 py-1 rounded-md text-xs font-medium cursor-pointer transition-opacity hover:opacity-80 bg-black/70 text-foreground"
          >
            <input
              type="file"
              accept={ACCEPT}
              className="hidden"
              onChange={onFileSelect}
            />
            Заменить
          </label>
          <Button
            type="button"
            size="sm"
            variant="secondary"
            onClick={() => onChange(null)}
            aria-label="Удалить обложку"
            className="bg-black/70 text-foreground border-0"
          >
            <X className="h-4 w-4" />
          </Button>
        </div>
        {upload.isPending && (
          <div className="absolute inset-0 bg-black/50 flex items-center justify-center">
            <TuranLoader variant="breathe" size={28} />
          </div>
        )}
      </div>
    );
  }

  return (
    <label
      onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
      onDragLeave={() => setDragging(false)}
      onDrop={onDrop}
      className={`flex flex-col items-center justify-center gap-2 cursor-pointer rounded-lg p-8 transition-colors aspect-[16/9] border-2 border-dashed ${
        dragging ? 'border-primary bg-primary/5' : 'border-border bg-secondary'
      }`}
    >
      <input type="file" accept={ACCEPT} className="hidden" onChange={onFileSelect} />
      {upload.isPending ? (
        <TuranLoader variant="breathe" size={28} />
      ) : (
        <>
          <div className="p-3 rounded-full bg-primary/10">
            {dragging ? (
              <Upload className="h-6 w-6 text-primary" />
            ) : (
              <ImageIcon className="h-6 w-6 text-primary" />
            )}
          </div>
          <p className="text-sm text-muted-foreground">
            Перетащите изображение или нажмите для выбора
          </p>
          <p className="text-xs text-muted-foreground/70">
            JPEG, PNG, WebP — макс. 5 МБ
          </p>
        </>
      )}
    </label>
  );
}

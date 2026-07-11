import { useState, useCallback } from 'react';
import { Link as LinkIcon } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { useParseArticleUrl, type ParsedArticle } from '@/hooks/useParseArticleUrl';

interface UrlParserInputProps {
  onParsed: (data: ParsedArticle) => void;
  onError: () => void;
}

export default function UrlParserInput({ onParsed, onError }: UrlParserInputProps) {
  const [url, setUrl] = useState('');
  const parseMutation = useParseArticleUrl();

  const handleParse = useCallback(async () => {
    if (!url.trim()) return;

    try {
      new URL(url); // validate URL
    } catch {
      return;
    }

    try {
      const data = await parseMutation.mutateAsync(url.trim());
      onParsed(data);
    } catch {
      onError();
    }
  }, [url, parseMutation, onParsed, onError]);

  const isLoading = parseMutation.isPending;

  return (
    <div className="space-y-4">
      {/* URL Input */}
      <div className="flex gap-2">
        <div className="relative flex-1">
          <LinkIcon className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
          <Input
            type="url"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') handleParse(); }}
            placeholder="Вставьте ссылку на статью (https://...)"
            className="pl-9 h-10 bg-secondary border-border"
            disabled={isLoading}
          />
        </div>
        <Button
          onClick={handleParse}
          disabled={!url.trim() || isLoading}
          className="h-10 px-5 bg-primary text-primary-foreground hover:bg-primary/90"
        >
          {isLoading ? (
            <TuranLoader variant="spin" size={16} />
          ) : (
            'Извлечь'
          )}
        </Button>
      </div>

      {/* Loading skeleton */}
      {isLoading && (
        <div className="p-4 rounded-lg space-y-3 bg-secondary border border-border">
          <p className="text-sm text-muted-foreground">
            Извлекаем данные из публикации...
          </p>
          <Skeleton className="h-[135px] w-[240px] rounded-lg bg-muted" />
          <Skeleton className="h-5 w-3/4 bg-muted" />
          <Skeleton className="h-4 w-full bg-muted" />
          <Skeleton className="h-4 w-2/3 bg-muted" />
        </div>
      )}

      {/* Error */}
      {parseMutation.isError && (
        <div className="p-3 rounded-lg text-sm bg-destructive/10 border border-destructive/20 text-destructive">
          Не удалось извлечь данные. Заполните форму вручную.
        </div>
      )}
    </div>
  );
}

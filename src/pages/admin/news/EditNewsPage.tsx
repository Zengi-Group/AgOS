import { useState, useCallback, useEffect } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Trash2 } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import ArticleForm, { type ArticleFormData } from './components/ArticleForm';
import ArticleSettings, { type ArticleSettingsData } from './components/ArticleSettings';
import ImageUpload from './components/ImageUpload';
import TagsInput from './components/TagsInput';
import { useAdminNewsArticle } from '@/hooks/useAdminNewsArticle';
import { useUpdateNewsArticle } from '@/hooks/useUpdateNewsArticle';
import { useDeleteNewsArticle } from '@/hooks/useDeleteNewsArticle';
import { parseVideoUrl } from './components/VideoEmbed';
import { toast } from 'sonner';
import { NEWS_CATEGORIES, adminInputStyle, adminSelectContentStyle, adminSelectItemClass } from './constants';

export default function EditNewsPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { data: article, isLoading } = useAdminNewsArticle(id);
  const updateMutation = useUpdateNewsArticle();
  const deleteMutation = useDeleteNewsArticle();

  // Association form state
  const [formData, setFormData] = useState<ArticleFormData>({
    title: '',
    slug: '',
    summary: '',
    content: '',
    cover_image_url: null,
    video_url: '',
  });

  const [settings, setSettings] = useState<ArticleSettingsData>({
    is_published: false,
    published_at: new Date().toISOString(),
    author: '',
    category: 'general',
    tags: [],
    is_featured: false,
    meta_title: '',
    meta_description: '',
  });

  // Media form state
  const [mediaForm, setMediaForm] = useState({
    title: '',
    summary: '',
    cover_image_url: null as string | null,
    source_name: '',
    source_url: '',
    published_at: '',
    category: 'general',
    tags: [] as string[],
    is_published: false,
    is_featured: false,
  });

  // Track unsaved changes
  const [dirty, setDirty] = useState(false);

  useEffect(() => {
    if (!dirty) return;
    const handler = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener('beforeunload', handler);
    return () => window.removeEventListener('beforeunload', handler);
  }, [dirty]);

  // Populate form when article loads
  useEffect(() => {
    if (!article) return;

    if (article.type === 'association') {
      setFormData({
        title: article.title,
        slug: article.slug,
        summary: article.summary ?? '',
        content: article.content ?? '',
        cover_image_url: article.cover_image_url,
        video_url: article.video_url ?? '',
      });
      setSettings({
        is_published: article.is_published,
        published_at: article.published_at,
        author: article.author ?? 'TURAN Standard Pool',
        category: article.category,
        tags: article.tags ?? [],
        is_featured: article.is_featured,
        meta_title: article.meta_title ?? '',
        meta_description: article.meta_description ?? '',
      });
    } else {
      setMediaForm({
        title: article.title,
        summary: article.summary ?? '',
        cover_image_url: article.cover_image_url,
        source_name: article.source_name ?? '',
        source_url: article.source_url ?? '',
        published_at: article.published_at.split('T')[0] ?? '',
        category: article.category,
        tags: article.tags ?? [],
        is_published: article.is_published,
        is_featured: article.is_featured,
      });
    }
  }, [article]);

  const updateForm = useCallback(
    (partial: Partial<ArticleFormData>) => {
      setDirty(true);
      setFormData((prev) => ({ ...prev, ...partial }));
    },
    [],
  );

  const updateSettings = useCallback(
    (partial: Partial<ArticleSettingsData>) => {
      setDirty(true);
      setSettings((prev) => ({ ...prev, ...partial }));
    },
    [],
  );

  const updateMedia = useCallback(
    (partial: Partial<typeof mediaForm>) => {
      setDirty(true);
      setMediaForm((prev) => ({ ...prev, ...partial }));
    },
    [],
  );

  const handleSaveAssociation = async (publish: boolean) => {
    if (!formData.title.trim() || !formData.slug.trim() || !formData.summary.trim()) {
      toast.error('Заполните обязательные поля');
      return;
    }

    const video = formData.video_url ? parseVideoUrl(formData.video_url) : null;

    try {
      await updateMutation.mutateAsync({
        id: id!,
        title: formData.title,
        slug: formData.slug,
        summary: formData.summary,
        content: formData.content,
        cover_image_url: formData.cover_image_url,
        video_url: formData.video_url || null,
        video_type: video?.type ?? null,
        author: settings.author || null,
        category: settings.category,
        tags: settings.tags,
        is_published: publish || settings.is_published,
        is_featured: settings.is_featured,
        published_at: settings.published_at,
        meta_title: settings.meta_title || null,
        meta_description: settings.meta_description || null,
      });
      toast.success('Статья обновлена');
      navigate('/admin/news');
    } catch {
      toast.error('Ошибка при сохранении');
    }
  };

  const handleSaveMedia = async (publish: boolean) => {
    if (!mediaForm.title.trim() || !mediaForm.summary.trim() || !mediaForm.source_name.trim()) {
      toast.error('Заполните обязательные поля');
      return;
    }

    try {
      await updateMutation.mutateAsync({
        id: id!,
        title: mediaForm.title,
        summary: mediaForm.summary,
        cover_image_url: mediaForm.cover_image_url,
        source_name: mediaForm.source_name,
        source_url: mediaForm.source_url,
        category: mediaForm.category,
        tags: mediaForm.tags,
        is_published: publish || mediaForm.is_published,
        is_featured: mediaForm.is_featured,
        published_at: new Date(mediaForm.published_at).toISOString(),
      });
      toast.success('Публикация обновлена');
      navigate('/admin/news');
    } catch {
      toast.error('Ошибка при сохранении');
    }
  };

  const handleDelete = async () => {
    try {
      await deleteMutation.mutateAsync(id!);
      toast.success('Новость удалена');
      navigate('/admin/news');
    } catch {
      toast.error('Ошибка при удалении');
    }
  };

  if (isLoading) {
    return (
      <div className="dark min-h-screen flex items-center justify-center bg-background">
        <TuranLoader variant="breathe" size={40} />
      </div>
    );
  }

  if (!article) {
    return (
      <div className="dark min-h-screen flex items-center justify-center bg-background">
        <p className="text-muted-foreground">Статья не найдена</p>
      </div>
    );
  }

  return (
    <div className="max-w-6xl mx-auto">
        {/* Back + Title */}
        <div className="flex items-center gap-3 mb-6">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => navigate('/admin/news')}
            className="p-1 text-muted-foreground"
          >
            <ArrowLeft className="h-5 w-5" />
          </Button>
          <h1 className="text-xl font-bold">
            Редактирование: {article.title}
          </h1>
        </div>

        {article.type === 'association' ? (
          /* ======= Association form (2-column) ======= */
          <>
            <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
              <div className="lg:col-span-3">
                <ArticleForm data={formData} onChange={updateForm} />
              </div>
              <div className="lg:col-span-2">
                <ArticleSettings data={settings} onChange={updateSettings} />
              </div>
            </div>

            {/* Footer */}
            <div className="sticky bottom-0 py-4 mt-6 flex gap-2 justify-between bg-background border-t border-border">
              <AlertDialog>
                <AlertDialogTrigger asChild>
                  <Button variant="ghost" className="gap-1.5 text-destructive">
                    <Trash2 className="h-4 w-4" /> Удалить
                  </Button>
                </AlertDialogTrigger>
                <AlertDialogContent className="dark bg-secondary border-border">
                  <AlertDialogHeader>
                    <AlertDialogTitle>Удалить новость?</AlertDialogTitle>
                    <AlertDialogDescription className="text-muted-foreground">
                      Действие необратимо.
                    </AlertDialogDescription>
                  </AlertDialogHeader>
                  <AlertDialogFooter>
                    <AlertDialogCancel className="bg-muted border-border">
                      Отмена
                    </AlertDialogCancel>
                    <AlertDialogAction onClick={handleDelete} className="bg-destructive text-destructive-foreground hover:bg-destructive/90">
                      Удалить
                    </AlertDialogAction>
                  </AlertDialogFooter>
                </AlertDialogContent>
              </AlertDialog>

              <div className="flex gap-2">
                <Button
                  variant="outline"
                  onClick={() => handleSaveAssociation(false)}
                  disabled={updateMutation.isPending}
                  className="bg-secondary border-border text-muted-foreground hover:bg-secondary/80"
                >
                  Сохранить черновик
                </Button>
                <Button
                  onClick={() => handleSaveAssociation(true)}
                  disabled={updateMutation.isPending}
                  className="bg-primary text-primary-foreground hover:bg-primary/90"
                >
                  {updateMutation.isPending ? 'Сохранение...' : 'Опубликовать'}
                </Button>
              </div>
            </div>
          </>
        ) : (
          /* ======= Media form (single column) ======= */
          <div className="max-w-[640px] mx-auto">
            <div className="p-5 rounded-lg space-y-5 bg-secondary border border-border">
              <ImageUpload
                value={mediaForm.cover_image_url}
                onChange={(url) => updateMedia({ cover_image_url: url })}
              />

              <div className="space-y-2">
                <Label>
                  Заголовок <span className="text-primary">*</span>
                </Label>
                <Input
                  value={mediaForm.title}
                  onChange={(e) => updateMedia({ title: e.target.value })}
                  className="h-10"
                  style={adminInputStyle}
                />
              </div>

              <div className="space-y-2">
                <div className="flex justify-between">
                  <Label>
                    Описание <span className="text-primary">*</span>
                  </Label>
                  <span className="text-xs text-muted-foreground">
                    {mediaForm.summary.length}/280
                  </span>
                </div>
                <Textarea
                  value={mediaForm.summary}
                  onChange={(e) => updateMedia({ summary: e.target.value.slice(0, 280) })}
                  rows={3}
                  style={adminInputStyle}
                />
              </div>

              <div className="space-y-2">
                <Label>
                  Издание <span className="text-primary">*</span>
                </Label>
                <Input
                  value={mediaForm.source_name}
                  onChange={(e) => updateMedia({ source_name: e.target.value })}
                  className="h-9"
                  style={adminInputStyle}
                />
              </div>

              <div className="space-y-2">
                <Label>URL оригинала</Label>
                <Input value={mediaForm.source_url} readOnly className="h-9 text-sm text-muted-foreground" style={adminInputStyle} />
              </div>

              <div className="space-y-2">
                <Label>Дата</Label>
                <Input
                  type="date"
                  value={mediaForm.published_at}
                  onChange={(e) => updateMedia({ published_at: e.target.value })}
                  className="h-9"
                  style={adminInputStyle}
                />
              </div>

              <div className="space-y-2">
                <Label>Категория</Label>
                <Select value={mediaForm.category} onValueChange={(v) => updateMedia({ category: v })}>
                  <SelectTrigger className="h-9" style={adminInputStyle}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent style={adminSelectContentStyle}>
                    {NEWS_CATEGORIES.map((c) => (
                      <SelectItem key={c.value} value={c.value} className={adminSelectItemClass}>{c.label}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <TagsInput value={mediaForm.tags} onChange={(tags) => updateMedia({ tags })} />

              <div className="pt-4 space-y-3 border-t border-border">
                <div className="flex items-center gap-4">
                  <div className="flex items-center gap-2">
                    <Checkbox
                      id="pub"
                      checked={mediaForm.is_published}
                      onCheckedChange={(v) => updateMedia({ is_published: !!v })}
                    />
                    <label htmlFor="pub" className="text-sm cursor-pointer">
                      Опубликовать сразу
                    </label>
                  </div>
                  <div className="flex items-center gap-2">
                    <Checkbox
                      id="feat"
                      checked={mediaForm.is_featured}
                      onCheckedChange={(v) => updateMedia({ is_featured: !!v })}
                    />
                    <label htmlFor="feat" className="text-sm cursor-pointer">
                      Избранное
                    </label>
                  </div>
                </div>

                <div className="flex gap-2 justify-between">
                  <AlertDialog>
                    <AlertDialogTrigger asChild>
                      <Button variant="ghost" className="gap-1.5 text-destructive">
                        <Trash2 className="h-4 w-4" /> Удалить
                      </Button>
                    </AlertDialogTrigger>
                    <AlertDialogContent className="dark bg-secondary border-border">
                      <AlertDialogHeader>
                        <AlertDialogTitle>Удалить новость?</AlertDialogTitle>
                        <AlertDialogDescription className="text-muted-foreground">
                          Действие необратимо.
                        </AlertDialogDescription>
                      </AlertDialogHeader>
                      <AlertDialogFooter>
                        <AlertDialogCancel className="bg-muted border-border">
                          Отмена
                        </AlertDialogCancel>
                        <AlertDialogAction onClick={handleDelete} className="bg-destructive text-destructive-foreground hover:bg-destructive/90">
                          Удалить
                        </AlertDialogAction>
                      </AlertDialogFooter>
                    </AlertDialogContent>
                  </AlertDialog>

                  <div className="flex gap-2">
                    <Button
                      variant="outline"
                      onClick={() => handleSaveMedia(false)}
                      disabled={updateMutation.isPending}
                      className="bg-muted border-border text-muted-foreground hover:bg-muted/80"
                    >
                      Сохранить черновик
                    </Button>
                    <Button
                      onClick={() => handleSaveMedia(true)}
                      disabled={updateMutation.isPending}
                      className="bg-primary text-primary-foreground hover:bg-primary/90"
                    >
                      {updateMutation.isPending ? 'Сохранение...' : 'Опубликовать'}
                    </Button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}
    </div>
  );
}

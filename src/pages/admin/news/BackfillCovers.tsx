import { useState, useEffect } from 'react';
import { supabase } from '@/lib/supabase';
import { CheckCircle2, XCircle, ImageIcon, Play } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';

interface StartupRow {
  id: string;
  title: string;
  pitch_deck_url: string | null;
  cover_image_url: string | null;
}

type Status = 'pending' | 'describing' | 'generating' | 'done' | 'error' | 'skipped';

interface StartupStatus extends StartupRow {
  status: Status;
  error?: string;
}

const EDGE_URL = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/backfill-covers`;

export default function BackfillCoversPage() {
  const [startups, setStartups] = useState<StartupStatus[]>([]);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);

  useEffect(() => {
    supabase
      .from('startups')
      .select('id, title, pitch_deck_url, cover_image_url')
      .not('pitch_deck_url', 'is', null)
      .order('created_at', { ascending: false })
      .then(({ data }) => {
        setStartups(
          (data || []).map((s) => ({
            ...s,
            status: s.cover_image_url ? 'done' : 'pending',
          }))
        );
        setLoading(false);
      });
  }, []);

  const processOne = async (startup: StartupStatus): Promise<void> => {
    const update = (patch: Partial<StartupStatus>) =>
      setStartups((prev) => prev.map((s) => (s.id === startup.id ? { ...s, ...patch } : s)));

    if (startup.cover_image_url) {
      update({ status: 'done' });
      return;
    }

    try {
      // Step 1: describe
      update({ status: 'describing' });
      const descResp = await fetch(EDGE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}`,
        },
        body: JSON.stringify({ startup_id: startup.id, mode: 'describe' }),
      });
      const descData = await descResp.json();
      if (!descResp.ok || !descData.prompt) {
        update({ status: 'error', error: descData.error || 'No prompt returned' });
        return;
      }

      // Step 2: generate image
      update({ status: 'generating' });
      const genResp = await fetch(EDGE_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY}`,
        },
        body: JSON.stringify({ startup_id: startup.id, mode: 'generate', prompt: descData.prompt }),
      });
      const genData = await genResp.json();
      if (!genResp.ok || !genData.cover_image_url) {
        update({ status: 'error', error: genData.error || 'No image returned' });
        return;
      }

      update({ status: 'done', cover_image_url: genData.cover_image_url });
    } catch (e) {
      update({ status: 'error', error: String(e) });
    }
  };

  const runAll = async () => {
    setRunning(true);
    const pending = startups.filter((s) => s.status === 'pending' || s.status === 'error');
    for (const s of pending) {
      await processOne(s);
    }
    setRunning(false);
  };

  const pendingCount = startups.filter((s) => s.status === 'pending').length;

  const statusIcon = (status: Status) => {
    if (status === 'done') return <CheckCircle2 size={16} className="text-[var(--green)]" />;
    if (status === 'error') return <XCircle size={16} className="text-[var(--red)]" />;
    if (status === 'describing' || status === 'generating')
      return <TuranLoader variant="spin" size={16} />;
    if (status === 'skipped') return <CheckCircle2 size={16} className="text-[var(--fg3)]" />;
    return <ImageIcon size={16} className="text-[var(--fg3)] opacity-60" />;
  };

  const statusLabel = (s: StartupStatus) => {
    if (s.status === 'done') return s.cover_image_url ? 'Готово' : 'Уже есть';
    if (s.status === 'describing') return 'Анализирую первый слайд...';
    if (s.status === 'generating') return 'Генерирую обложку...';
    if (s.status === 'error') return `Ошибка: ${s.error}`;
    return 'Ожидает';
  };

  return (
    <div className="min-h-screen px-4 py-6 max-w-3xl mx-auto" style={{ background: 'var(--bg)' }}>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold" style={{ color: 'var(--fg)' }}>
            Обложки стартапов
          </h1>
          <p className="text-sm mt-1" style={{ color: 'var(--fg3)' }}>
            Автоматическая генерация обложек из первого слайда Pitch Deck
          </p>
        </div>
        {pendingCount > 0 && (
          <button
            onClick={runAll}
            disabled={running}
            className="inline-flex items-center gap-2 px-4 py-2 rounded-xl text-sm font-medium text-white disabled:opacity-60"
            style={{ background: 'var(--brand)' }}
          >
            {running ? <TuranLoader variant="spin" size={15} /> : <Play size={15} />}
            {running ? 'Обрабатываю...' : `Запустить (${pendingCount})`}
          </button>
        )}
      </div>

      {loading ? (
        <div className="flex justify-center py-12">
          <TuranLoader variant="breathe" size={40} />
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          {startups.map((s) => (
            <div
              key={s.id}
              className="flex items-center gap-4 p-4 rounded-xl"
              style={{ background: 'var(--bg-c)', border: '1px solid var(--bd-s)' }}
            >
              {/* Cover preview */}
              <div
                className="w-20 h-12 rounded-lg flex-shrink-0 overflow-hidden"
                style={{ background: 'var(--bg-m)' }}
              >
                {s.cover_image_url && s.status === 'done' ? (
                  <img src={s.cover_image_url} alt="" className="w-full h-full object-cover" />
                ) : (
                  <div className="w-full h-full flex items-center justify-center">
                    <ImageIcon size={16} style={{ color: 'var(--fg3)' }} />
                  </div>
                )}
              </div>

              {/* Info */}
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate" style={{ color: 'var(--fg)' }}>
                  {s.title}
                </p>
                <p className="text-xs mt-0.5 flex items-center gap-1" style={{ color: 'var(--fg3)' }}>
                  {statusIcon(s.status)}
                  {statusLabel(s)}
                </p>
              </div>

              {/* Retry button for errors */}
              {s.status === 'error' && !running && (
                <button
                  onClick={() => processOne(s)}
                  className="text-xs px-3 py-1.5 rounded-lg"
                  style={{ background: 'var(--bg-m)', color: 'var(--fg)' }}
                >
                  Повторить
                </button>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

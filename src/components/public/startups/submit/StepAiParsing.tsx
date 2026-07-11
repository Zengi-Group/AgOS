import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { TuranLoader } from '@/components/TuranLoader';

const STATUS_KEYS = [
  'startups.submit.aiStatus1',
  'startups.submit.aiStatus2',
  'startups.submit.aiStatus3',
];

interface Props {
  onTimeout: () => void;
}

export default function StepAiParsing({ onTimeout }: Props) {
  const { t } = useTranslation();
  const [statusIdx, setStatusIdx] = useState(0);
  const [elapsed, setElapsed] = useState(0);

  // Cycle through status messages
  useEffect(() => {
    const interval = setInterval(() => {
      setStatusIdx((prev) => (prev + 1) % STATUS_KEYS.length);
    }, 3000);
    return () => clearInterval(interval);
  }, []);

  // Track elapsed time for timeout
  useEffect(() => {
    const interval = setInterval(() => {
      setElapsed((prev) => prev + 1);
    }, 1000);
    return () => clearInterval(interval);
  }, []);

  // 60s timeout
  useEffect(() => {
    if (elapsed >= 60) {
      onTimeout();
    }
  }, [elapsed, onTimeout]);

  const progress = Math.min(95, elapsed * 1.5);

  return (
    <div className="flex flex-col items-center justify-center py-12 gap-6">
      {/* Spinner */}
      <div
        className="w-16 h-16 rounded-2xl flex items-center justify-center"
        style={{ background: 'rgba(232,115,12,0.08)' }}
      >
        <TuranLoader variant="breathe" size={40} />
      </div>

      {/* Status text */}
      <div className="text-center">
        <h2 className="font-serif font-semibold text-[18px] mb-2" style={{ color: '#2B180A' }}>
          {t('startups.submit.aiParsingTitle')}
        </h2>
        <p
          className="text-[14px] transition-opacity duration-300"
          style={{ color: 'rgba(43,24,10,0.5)' }}
          key={statusIdx}
        >
          {t(STATUS_KEYS[statusIdx] ?? '')}
        </p>
      </div>

      {/* Progress bar */}
      <div className="w-full max-w-[280px]">
        <div className="h-1.5 rounded-full" style={{ background: 'rgba(43,24,10,0.06)' }}>
          <div
            className="h-full rounded-full transition-all duration-1000 ease-out"
            style={{
              width: `${progress}%`,
              background: 'linear-gradient(90deg, #E8730C, #F0933C)',
            }}
          />
        </div>
      </div>

      {/* Elapsed indicator */}
      <p className="text-[11px]" style={{ color: 'rgba(43,24,10,0.25)' }}>
        {elapsed}s
      </p>
    </div>
  );
}

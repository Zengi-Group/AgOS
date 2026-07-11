import { useState, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import { Dialog, DialogContent, DialogTitle } from '@/components/ui/dialog';
import { ArrowLeft, ArrowRight, Send } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import type { SubmitStartupFormData, AiParsedData } from '@/types/startup';
import { uploadPitchDeck, parsePitchDeck, useSubmitStartup } from '@/hooks/startups/useSubmitStartup';
import StepBasicInfo from './StepBasicInfo';
import StepAiParsing from './StepAiParsing';
import StepReviewForm from './StepReviewForm';
import StepSuccess from './StepSuccess';

const INITIAL_FORM: SubmitStartupFormData = {
  title: '',
  website_url: '',
  contact_name: '',
  contact_email: '',
  contact_phone: '',
  tagline: '',
  category: '',
  stage: '',
  description_problem: '',
  description_solution: '',
  target_market: '',
  business_model: '',
  funding_ask: '',
  funding_instrument: '',
  year_founded: '',
  team_size: '',
  location_region: '',
  team_members: [],
  use_of_funds: [],
};

const STEP_LABELS = [
  'startups.submit.stepLabel1',
  'startups.submit.stepLabel2',
  'startups.submit.stepLabel3',
  'startups.submit.stepLabel4',
];

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export default function SubmitStartupModal({ open, onOpenChange }: Props) {
  const { t } = useTranslation();
  const [step, setStep] = useState(0);
  const [formData, setFormData] = useState<SubmitStartupFormData>(INITIAL_FORM);
  const [file, setFile] = useState<File | null>(null);
  const [pitchDeckUrl, setPitchDeckUrl] = useState('');
  const [coverImageUrl, setCoverImageUrl] = useState<string | null>(null);
  const [aiFields, setAiFields] = useState<Set<string>>(new Set());
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [uploading, setUploading] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const submitMutation = useSubmitStartup();

  // ─── Field change handlers ──────────────────────────────
  const handleBasicChange = useCallback((field: string, value: string) => {
    setFormData((prev) => ({ ...prev, [field]: value }));
    setErrors((prev) => {
      const next = { ...prev };
      delete next[field];
      return next;
    });
  }, []);

  const handleReviewChange = useCallback((field: string, value: any) => {
    setFormData((prev) => ({ ...prev, [field]: value }));
    setAiFields((prev) => {
      const next = new Set(prev);
      next.delete(field);
      return next;
    });
    setErrors((prev) => {
      const next = { ...prev };
      delete next[field];
      return next;
    });
  }, []);

  // ─── Validation ─────────────────────────────────────────
  const validateStep1 = (): boolean => {
    const errs: Record<string, string> = {};
    if (!formData.title.trim()) errs.title = t('startups.submit.errorRequired');
    if (!formData.contact_name.trim()) errs.contact_name = t('startups.submit.errorRequired');
    if (!formData.contact_email.trim()) {
      errs.contact_email = t('startups.submit.errorRequired');
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(formData.contact_email)) {
      errs.contact_email = t('startups.submit.errorEmail');
    }
    if (!file) errs.file = t('startups.submit.errorRequired');
    setErrors(errs);
    return Object.keys(errs).length === 0;
  };

  const validateStep3 = (): boolean => {
    const errs: Record<string, string> = {};
    if (!formData.title.trim()) errs.title = t('startups.submit.errorRequired');
    if (!formData.category) errs.category = t('startups.submit.errorRequired');
    if (!formData.stage) errs.stage = t('startups.submit.errorRequired');
    setErrors(errs);
    return Object.keys(errs).length === 0;
  };

  // ─── Step navigation ────────────────────────────────────
  const goNextFromStep1 = async () => {
    if (!validateStep1() || !file) return;

    setUploading(true);
    try {
      const { publicUrl, storagePath } = await uploadPitchDeck(file);
      setPitchDeckUrl(publicUrl);
      setStep(1);
      // Start AI parsing automatically
      try {
        const parsed = await parsePitchDeck(storagePath);
        if (parsed.cover_image_url) {
          setCoverImageUrl(parsed.cover_image_url);
        }
        applyAiResults(parsed);
        setStep(2);
      } catch {
        // AI failed — go to review with blank fields
        setStep(2);
      }
    } catch {
      setErrors({ file: t('startups.submit.errorUpload') });
    } finally {
      setUploading(false);
    }
  };

  const applyAiResults = (parsed: AiParsedData) => {
    const filledKeys = new Set<string>();

    setFormData((prev) => {
      const next = { ...prev };
      const fields: (keyof AiParsedData)[] = [
        'tagline', 'category', 'stage',
        'description_problem', 'description_solution',
        'target_market', 'business_model',
        'funding_instrument', 'location_region',
      ];
      for (const key of fields) {
        if (parsed[key] && !prev[key as keyof SubmitStartupFormData]) {
          (next as any)[key] = parsed[key];
          filledKeys.add(key);
        }
      }

      if (parsed.funding_ask && !prev.funding_ask) {
        next.funding_ask = String(parsed.funding_ask);
        filledKeys.add('funding_ask');
      }
      if (parsed.year_founded && !prev.year_founded) {
        next.year_founded = String(parsed.year_founded);
        filledKeys.add('year_founded');
      }
      if (parsed.team_size && !prev.team_size) {
        next.team_size = String(parsed.team_size);
        filledKeys.add('team_size');
      }
      if (parsed.team_members?.length && prev.team_members.length === 0) {
        next.team_members = parsed.team_members;
        filledKeys.add('team_members');
      }
      if (parsed.use_of_funds?.length && prev.use_of_funds.length === 0) {
        next.use_of_funds = parsed.use_of_funds;
        filledKeys.add('use_of_funds');
      }
      return next;
    });

    setAiFields(filledKeys);
  };

  const handleAiTimeout = useCallback(() => {
    // Timeout — skip to review step with whatever data we have
    setStep(2);
  }, []);

  const handleSubmit = async () => {
    if (!validateStep3()) return;

    setSubmitting(true);
    try {
      await submitMutation.mutateAsync({
        formData,
        pitchDeckUrl,
        coverImageUrl,
      });
      setStep(3);
    } catch {
      setErrors({ _submit: t('startups.submit.errorSubmit') });
    } finally {
      setSubmitting(false);
    }
  };

  const handleClose = () => {
    // Reset all state
    setStep(0);
    setFormData(INITIAL_FORM);
    setFile(null);
    setPitchDeckUrl('');
    setCoverImageUrl(null);
    setAiFields(new Set());
    setErrors({});
    setUploading(false);
    setSubmitting(false);
    onOpenChange(false);
  };

  // ─── Render ─────────────────────────────────────────────
  const isProcessing = step === 1;
  const isSuccess = step === 3;

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) handleClose(); }}>
      <DialogContent
        className="max-w-[600px] w-full max-h-[90dvh] overflow-y-auto rounded-[16px] p-0 md:p-0 border-none
          data-[state=open]:!slide-in-from-bottom-4 data-[state=open]:!slide-in-from-left-0 data-[state=open]:!slide-in-from-top-0
          max-md:!top-auto max-md:!bottom-0 max-md:!translate-y-0 max-md:!translate-x-[-50%] max-md:!left-[50%]
          max-md:max-h-[95dvh] max-md:rounded-b-none max-md:rounded-t-[20px]"
        style={{ background: '#fdf6ee' }}
        onInteractOutside={(e) => { if (isProcessing) e.preventDefault(); }}
      >
        <DialogTitle className="sr-only">{t('startups.submit.modalTitle')}</DialogTitle>

        <div className="px-5 md:px-7 py-6 md:py-8">
          {/* Stepper */}
          {!isSuccess && (
            <div className="flex items-center gap-2 mb-6">
              {STEP_LABELS.map((label, i) => (
                <div key={i} className="flex items-center gap-2 flex-1">
                  <div
                    className="flex items-center justify-center w-6 h-6 rounded-full text-[11px] font-semibold transition-colors"
                    style={{
                      background: i <= step ? '#E8730C' : 'rgba(43,24,10,0.08)',
                      color: i <= step ? '#fff' : 'rgba(43,24,10,0.35)',
                    }}
                  >
                    {i + 1}
                  </div>
                  <span
                    className="text-[11px] font-medium hidden sm:inline"
                    style={{ color: i <= step ? '#2B180A' : 'rgba(43,24,10,0.3)' }}
                  >
                    {t(label)}
                  </span>
                  {i < STEP_LABELS.length - 1 && (
                    <div className="flex-1 h-px" style={{ background: 'rgba(43,24,10,0.08)' }} />
                  )}
                </div>
              ))}
            </div>
          )}

          {/* Step content */}
          {step === 0 && (
            <StepBasicInfo
              data={formData}
              file={file}
              errors={errors}
              onChange={handleBasicChange}
              onFileChange={setFile}
            />
          )}

          {step === 1 && (
            <StepAiParsing onTimeout={handleAiTimeout} />
          )}

          {step === 2 && (
            <StepReviewForm
              data={formData}
              aiFields={aiFields}
              errors={errors}
              onChange={handleReviewChange}
            />
          )}

          {step === 3 && (
            <StepSuccess onClose={handleClose} />
          )}

          {/* Footer actions */}
          {step === 0 && (
            <div className="flex items-center justify-between mt-6 pt-5" style={{ borderTop: '1px solid rgba(43,24,10,0.06)' }}>
              <button
                type="button"
                onClick={handleClose}
                className="px-4 py-2.5 text-[14px] font-medium rounded-xl transition-colors hover:bg-black/5"
                style={{ color: 'rgba(43,24,10,0.5)' }}
              >
                {t('startups.submit.cancel')}
              </button>
              <button
                type="button"
                onClick={goNextFromStep1}
                disabled={uploading}
                className="inline-flex items-center gap-2 px-5 py-2.5 text-[14px] font-medium rounded-xl text-white transition-all hover:brightness-90 disabled:opacity-60"
                style={{ backgroundColor: '#E8730C' }}
              >
                {uploading ? (
                  <TuranLoader variant="spin" size={16} />
                ) : (
                  <ArrowRight size={16} />
                )}
                {uploading ? t('startups.submit.uploading') : t('startups.submit.next')}
              </button>
            </div>
          )}

          {step === 2 && (
            <div className="flex flex-col gap-3 mt-6 pt-5" style={{ borderTop: '1px solid rgba(43,24,10,0.06)' }}>
              {errors._submit && (
                <p className="text-[13px] font-medium text-center" style={{ color: '#993333' }}>
                  {errors._submit}
                </p>
              )}
              <div className="flex items-center justify-between">
                <button
                  type="button"
                  onClick={() => { setStep(0); setErrors({}); }}
                  className="inline-flex items-center gap-1.5 px-4 py-2.5 text-[14px] font-medium rounded-xl transition-colors hover:bg-black/5"
                  style={{ color: 'rgba(43,24,10,0.5)' }}
                >
                  <ArrowLeft size={16} />
                  {t('startups.submit.back')}
                </button>
                <button
                  type="button"
                  onClick={handleSubmit}
                  disabled={submitting}
                  className="inline-flex items-center gap-2 px-6 py-2.5 text-[14px] font-medium rounded-xl text-white transition-all hover:brightness-90 disabled:opacity-60"
                  style={{ backgroundColor: '#3f2407' }}
                >
                  {submitting ? (
                    <TuranLoader variant="spin" size={16} />
                  ) : (
                    <Send size={16} />
                  )}
                  {submitting ? t('startups.submit.submitting') : t('startups.submit.submitButton')}
                </button>
              </div>
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}

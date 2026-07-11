import { useState, useMemo, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import { useSearchParams, useNavigate } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Switch } from '@/components/ui/switch';
import { ArrowLeft, ArrowRight, Check, CheckCircle2, AlertTriangle, Lock, Hammer, Sparkles } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { useFinancePrograms } from '@/hooks/finance/useFinancePrograms';
import { computeRoadmap, determineSegment } from '@/lib/finance/engine';
import { useSaveProject } from '@/hooks/finance/useSaveProject';
import { useAuth } from '@/hooks/useAuth';
import { toast } from 'sonner';

import type { GoalType, ProjectInputs, ComputedStage } from '@/types/finance';
import { GOAL_OPTIONS } from '@/types/finance';

const TOTAL_STEPS = 4;

/* ─── Shared OptionCard (same as SubsidyMatch) ─── */
function OptionCard({
  selected,
  onClick,
  title,
  subtitle,
  icon,
}: {
  selected: boolean;
  onClick: () => void;
  title: string;
  subtitle?: string;
  icon?: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className={`group w-full text-left px-3 py-2.5 sm:px-5 sm:py-4 rounded-[11px] sm:rounded-[13px] border transition-all duration-200 ${
        selected
          ? 'border-[#3f2407] bg-[#3f2407]/[0.04] shadow-[0_0_0_1px_#3f2407]'
          : 'border-[#2b180914] bg-white/60 hover:border-[#2b180930] hover:bg-white/80'
      }`}
    >
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0 flex-1">
          {icon && <div className="shrink-0">{icon}</div>}
          <div className="min-w-0 flex-1">
            <span className="block font-medium text-[13.5px] sm:text-base text-foreground leading-snug">{title}</span>
            {subtitle && (
              <span className="block text-[12px] sm:text-[13px] text-muted-foreground mt-0.5 leading-snug">{subtitle}</span>
            )}
          </div>
        </div>
        <div
          className={`shrink-0 flex items-center justify-center rounded-full w-5 h-5 transition-all duration-200 ${
            selected
              ? 'bg-[#3f2407] text-white'
              : 'border-2 border-[#2b180920] bg-transparent'
          }`}
        >
          {selected && <Check className="w-3 h-3" strokeWidth={3} />}
        </div>
      </div>
    </button>
  );
}

/* ─── Switch row with consistent style ─── */
function SwitchRow({ label, checked, onCheck }: { label: string; checked: boolean; onCheck: (v: boolean) => void }) {
  return (
    <div className="flex items-center justify-between gap-3 px-3 py-2.5 sm:px-4 sm:py-3 rounded-[11px] sm:rounded-[13px] border border-[#2b180914] bg-white/60">
      <Label className="flex-1 text-[13.5px] sm:text-sm font-medium text-foreground cursor-pointer">{label}</Label>
      <Switch checked={checked} onCheckedChange={onCheck} />
    </div>
  );
}

const ProjectBuilder = () => {
  const { t, i18n } = useTranslation();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { user } = useAuth();
  const { data: programData, isLoading } = useFinancePrograms();
  const saveProject = useSaveProject();

  const skipIntent = searchParams.has('goal') || searchParams.has('program') || searchParams.get('intent') === 'project';
  const [step, setStep] = useState<number>(skipIntent ? 1 : 0);
  const [inputs, setInputs] = useState<ProjectInputs>({
    goal_type: (searchParams.get('goal') as GoalType) || 'start_farm',
    is_agri_producer: false,
    land_area: 0,
    has_feed_base: false,
    has_farm: false,
    herd_size: 0,
    target_herd_size: 100,
    import_livestock: false,
    need_infrastructure: false,
  });

  const prefillProgram = searchParams.get('program');

  useEffect(() => {
    const goal = searchParams.get('goal') as GoalType;
    const program = searchParams.get('program');
    const updates: Partial<ProjectInputs> = {};
    if (goal && GOAL_OPTIONS.some((o) => o.value === goal)) updates.goal_type = goal;
    if (program === 'bereke') { updates.is_agri_producer = true; updates.has_feed_base = true; if (!goal) updates.goal_type = 'add_livestock'; }
    else if (program === 'zhaylau') { updates.need_infrastructure = true; if (!goal) updates.goal_type = 'start_farm'; }
    else if (program === 'sybaga') { updates.is_agri_producer = true; if (!goal) updates.goal_type = 'increase_herd'; }
    else if (program === 'import_livestock') { updates.import_livestock = true; updates.is_agri_producer = true; if (!goal) updates.goal_type = 'expand_farm'; }
    else if (program === 'working_capital') { updates.is_agri_producer = true; updates.has_farm = true; if (!goal) updates.goal_type = 'working_capital'; }
    if (Object.keys(updates).length > 0) setInputs((prev) => ({ ...prev, ...updates }));
  }, [searchParams]);

  const update = <K extends keyof ProjectInputs>(key: K, value: ProjectInputs[K]) =>
    setInputs((prev) => ({ ...prev, [key]: value }));

  const segment = useMemo(() => determineSegment(inputs), [inputs]);
  const lang = i18n.language?.startsWith('kk') ? 'kz' : i18n.language || 'ru';

  const stages: ComputedStage[] = useMemo(() => {
    if (!programData) return [];
    return computeRoadmap(programData.programs, programData.deps, inputs, lang);
  }, [programData, inputs, lang]);

  useEffect(() => {
    if (step === 4) localStorage.setItem('finance_profile', JSON.stringify(inputs));
  }, [step, inputs]);

  const handleSave = async () => {
    if (!user) { toast.error(t('finance.loginRequired')); navigate('/login?redirect=/finance/build'); return; }
    try { await saveProject.mutateAsync({ inputs, segment, stages }); toast.success(t('finance.projectSaved')); navigate('/cabinet'); }
    catch { toast.error(t('finance.saveError')); }
  };

  const programName = (p: ComputedStage['program']) => {
    if (lang === 'kz') return p.name_kz || p.name_ru;
    if (lang === 'en') return p.name_en || p.name_ru;
    return p.name_ru;
  };

  const programDesc = (p: ComputedStage['program']) => {
    if (lang === 'kz') return p.role_in_project_kz || p.role_in_project_ru;
    return p.role_in_project_ru;
  };

  /* ─── Step header (same as SubsidyMatch) ─── */
  const StepHeader = ({ title, subtitle }: { title: string; subtitle?: string }) => (
    <div className="mb-4 sm:mb-6">
      {step > 0 && (
        <div className="flex items-center gap-2 mb-0.5">
          <span className="text-[11px] sm:text-xs font-medium text-muted-foreground uppercase tracking-wider">
            {t('subsidies.match.stepOf', { current: step, total: TOTAL_STEPS })}
          </span>
        </div>
      )}
      <h2 className="font-serif text-[20px] sm:text-[26px] font-bold text-foreground leading-tight tracking-tight">
        {title}
      </h2>
      {subtitle && (
        <p className="text-[13px] sm:text-sm text-muted-foreground mt-1">{subtitle}</p>
      )}
    </div>
  );

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <TuranLoader variant="breathe" size={40} />
      </div>
    );
  }

  return (
    <div className="noise-overlay min-h-screen flex flex-col bg-background">
      

      <main className="flex-1 pt-4 sm:pt-10 md:pt-14 pb-20 sm:pb-28 px-4 sm:px-6">
        <div className="max-w-[600px] mx-auto">

          {/* ─── Step 0: Intent chooser ─── */}
          {step === 0 && (
            <div>
              <StepHeader
                title={t('finance.builder.intent.title')}
                subtitle={t('finance.builder.intent.subtitle')}
              />
              <div className="space-y-2 sm:space-y-3">
                <button
                  onClick={() => setStep(1)}
                  className="w-full text-left px-3 py-2.5 sm:px-5 sm:py-4 rounded-[11px] sm:rounded-[13px] border border-[#2b180914] bg-white/60 hover:border-[#2b180930] hover:bg-white/80 transition-all duration-200"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 sm:w-10 sm:h-10 rounded-[9px] bg-[#3f2407]/10 flex items-center justify-center shrink-0">
                      <Hammer className="h-4 w-4 sm:h-5 sm:w-5 text-[#3f2407]" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <span className="block font-medium text-[13.5px] sm:text-base text-foreground leading-snug">
                        {t('finance.builder.intent.project')}
                      </span>
                      <span className="block text-[12px] sm:text-[13px] text-muted-foreground mt-0.5 leading-snug">
                        {t('finance.builder.intent.projectDesc')}
                      </span>
                    </div>
                  </div>
                </button>

                <button
                  onClick={() => navigate('/subsidies/match')}
                  className="w-full text-left px-3 py-2.5 sm:px-5 sm:py-4 rounded-[11px] sm:rounded-[13px] border border-[#2b180914] bg-white/60 hover:border-[#2b180930] hover:bg-white/80 transition-all duration-200"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 sm:w-10 sm:h-10 rounded-[9px] bg-emerald-600/10 flex items-center justify-center shrink-0">
                      <Sparkles className="h-4 w-4 sm:h-5 sm:w-5 text-emerald-700" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <span className="block font-medium text-[13.5px] sm:text-base text-foreground leading-snug">
                        {t('finance.builder.intent.reimbursement')}
                      </span>
                      <span className="block text-[12px] sm:text-[13px] text-muted-foreground mt-0.5 leading-snug">
                        {t('finance.builder.intent.reimbursementDesc')}
                      </span>
                    </div>
                  </div>
                </button>

                <button
                  onClick={() => navigate('/finance')}
                  className="w-full text-center py-2.5 text-[13px] text-muted-foreground hover:text-foreground underline underline-offset-4 transition-colors"
                >
                  {t('finance.builder.intent.showAll')}
                </button>
              </div>
            </div>
          )}

          {/* Pre-fill banner */}
          {prefillProgram && step === 1 && (
            <div className="flex items-center gap-3 px-3 py-2.5 rounded-[11px] border border-[#3f2407]/15 bg-[#3f2407]/[0.04] mb-4">
              <CheckCircle2 className="h-4 w-4 text-[#3f2407] shrink-0" />
              <p className="text-[13px] text-foreground">
                {t('finance.builder.prefillNote', { program: prefillProgram })}
              </p>
            </div>
          )}

          {/* ─── Step 1: Goal ─── */}
          {step === 1 && (
            <div>
              <StepHeader title={t('finance.builder.step1_title')} />
              <div className="space-y-2 sm:space-y-3">
                {GOAL_OPTIONS.map(({ value, labelKey }) => (
                  <OptionCard
                    key={value}
                    selected={inputs.goal_type === value}
                    onClick={() => update('goal_type', value)}
                    title={t(labelKey)}
                    subtitle={t(`${labelKey}_desc`)}
                  />
                ))}
              </div>
            </div>
          )}

          {/* ─── Step 2: Context ─── */}
          {step === 2 && (
            <div>
              <StepHeader title={t('finance.builder.step2_title')} />
              <div className="space-y-2 sm:space-y-3">
                <SwitchRow label={t('finance.fields.is_agri_producer')} checked={inputs.is_agri_producer} onCheck={(v) => update('is_agri_producer', v)} />
                <SwitchRow label={t('finance.fields.has_feed_base')} checked={inputs.has_feed_base} onCheck={(v) => update('has_feed_base', v)} />
                <SwitchRow label={t('finance.fields.has_farm')} checked={inputs.has_farm} onCheck={(v) => update('has_farm', v)} />

                <div className="rounded-[11px] sm:rounded-[13px] border border-[#2b180914] bg-white/60 px-3 py-3 sm:px-4 sm:py-3.5 space-y-3">
                  <div className="space-y-1.5">
                    <Label className="text-[13px] font-medium text-muted-foreground">{t('finance.fields.land_area')}</Label>
                    <Input
                      type="number"
                      inputMode="numeric"
                      min={0}
                      value={inputs.land_area || ''}
                      onChange={(e) => update('land_area', Number(e.target.value))}
                      placeholder="0"
                      className="h-10 text-base rounded-[9px] border-[#2b180914]"
                    />
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <div className="space-y-1.5">
                      <Label className="text-[13px] font-medium text-muted-foreground">{t('finance.fields.herd_size')}</Label>
                      <Input
                        type="number"
                        inputMode="numeric"
                        min={0}
                        value={inputs.herd_size || ''}
                        onChange={(e) => update('herd_size', Number(e.target.value))}
                        placeholder="0"
                        className="h-10 text-base rounded-[9px] border-[#2b180914]"
                      />
                    </div>
                    <div className="space-y-1.5">
                      <Label className="text-[13px] font-medium text-muted-foreground">{t('finance.fields.target_herd_size')}</Label>
                      <Input
                        type="number"
                        inputMode="numeric"
                        min={1}
                        value={inputs.target_herd_size || ''}
                        onChange={(e) => update('target_herd_size', Number(e.target.value))}
                        placeholder="100"
                        className="h-10 text-base rounded-[9px] border-[#2b180914]"
                      />
                    </div>
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* ─── Step 3: Advanced ─── */}
          {step === 3 && (
            <div>
              <StepHeader title={t('finance.builder.step3_title')} />
              <div className="space-y-2 sm:space-y-3">
                <SwitchRow label={t('finance.fields.import_livestock')} checked={inputs.import_livestock} onCheck={(v) => update('import_livestock', v)} />
                <SwitchRow label={t('finance.fields.need_infrastructure')} checked={inputs.need_infrastructure} onCheck={(v) => update('need_infrastructure', v)} />

                <div className="rounded-[11px] sm:rounded-[13px] border border-[#2b180914] bg-white/60 px-3 py-2.5 sm:px-4 sm:py-3">
                  <p className="text-[13px] text-muted-foreground">{t('finance.builder.segment_label')}</p>
                  <Badge className="mt-1.5 text-[11px] bg-[#f1e7dc] text-[#786758] border-0 hover:bg-[#e8ddd0]">
                    {t(`finance.segments.${segment}`)}
                  </Badge>
                </div>
              </div>
            </div>
          )}

          {/* ─── Step 4: Roadmap ─── */}
          {step === 4 && (
            <div>
              <StepHeader title={t('finance.builder.step4_title')} />

              {stages.length === 0 ? (
                <div className="rounded-2xl border border-[#2b180910] bg-white/70 p-8 text-center">
                  <p className="text-muted-foreground">{t('finance.noPrograms')}</p>
                </div>
              ) : (
                <div className="space-y-2 sm:space-y-3">
                  {stages.map((stage) => (
                    <div
                      key={stage.program.id}
                      className={`relative rounded-[11px] sm:rounded-[13px] border px-3 py-2.5 sm:px-4 sm:py-3.5 transition-all ${
                        stage.status === 'available'
                          ? 'border-emerald-300/60 bg-emerald-50/40'
                          : stage.status === 'conditional'
                          ? 'border-amber-300/60 bg-amber-50/40'
                          : 'border-[#2b180914] bg-white/40 opacity-60'
                      }`}
                    >
                      <div className="flex gap-3">
                        <div className="shrink-0 pt-0.5">
                          {stage.status === 'available' && <CheckCircle2 className="h-[18px] w-[18px] text-emerald-600" />}
                          {stage.status === 'conditional' && <AlertTriangle className="h-[18px] w-[18px] text-yellow-600" />}
                          {stage.status === 'locked' && <Lock className="h-[18px] w-[18px] text-muted-foreground" />}
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="flex items-center gap-2 flex-wrap">
                            <h3 className="font-medium text-[13.5px] sm:text-base text-foreground leading-snug">
                              {programName(stage.program)}
                            </h3>
                            <Badge className="text-[10px] bg-[#f1e7dc] text-[#786758] border-0 hover:bg-[#e8ddd0]">
                              {stage.program.type === 'credit' ? t('finance.typeCredit') : t('finance.typeSubsidy')}
                            </Badge>
                          </div>
                          {programDesc(stage.program) && (
                            <p className="text-[12px] sm:text-[13px] text-muted-foreground mt-0.5 leading-snug">
                              {programDesc(stage.program)}
                            </p>
                          )}
                          {stage.reason && (
                            <p className="text-[11px] text-destructive mt-1.5 flex items-center gap-1">
                              <AlertTriangle className="h-3 w-3" />
                              {stage.reason}
                            </p>
                          )}
                          {stage.program.limits_max > 0 && (
                            <p className="text-[11px] text-muted-foreground mt-1">
                              {t('finance.limits')}: {formatMoney(stage.program.limits_min)} – {formatMoney(stage.program.limits_max)} ₸
                            </p>
                          )}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

        </div>
      </main>

      {/* ─── Sticky bottom bar (identical to SubsidyMatch) ─── */}
      <div
        className="fixed bottom-0 left-0 right-0 z-40"
        style={{
          backgroundColor: 'rgba(253, 246, 238, 0.88)',
          backdropFilter: 'blur(16px)',
          WebkitBackdropFilter: 'blur(16px)',
          borderTop: '1px solid rgba(43,24,10,0.07)',
          boxShadow: '0 -8px 32px rgba(0,0,0,0.07)',
        }}
      >
        <div className="max-w-[600px] mx-auto px-4 py-3 flex items-center gap-3">
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              if (step === 0) return navigate('/finance');
              if (step === 1) return skipIntent ? navigate('/finance') : setStep(0);
              setStep(step - 1);
            }}
            className="gap-1.5 shrink-0 rounded-[9px] text-[13px] h-9"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            {t('finance.back')}
          </Button>

          {step > 0 ? (
            <div className="flex items-center gap-1.5 flex-1 justify-center">
              {Array.from({ length: TOTAL_STEPS }).map((_, i) => (
                <div
                  key={i}
                  className="rounded-full transition-all duration-500"
                  style={{
                    width: i + 1 === step ? 20 : 6,
                    height: 6,
                    backgroundColor: i < step ? '#E8730C' : 'rgba(43,24,10,0.15)',
                  }}
                />
              ))}
            </div>
          ) : (
            <div className="flex-1" />
          )}

          {step === 0 ? (
            <div className="w-[72px]" />
          ) : step < TOTAL_STEPS ? (
            <Button
              size="sm"
              onClick={() => setStep(step + 1)}
              className="gap-1.5 shrink-0 rounded-[9px] text-[13px] h-9 bg-[#3f2407] hover:bg-[#2b1809]"
            >
              {t('finance.next')}
              <ArrowRight className="h-3.5 w-3.5" />
            </Button>
          ) : (
            <Button
              size="sm"
              onClick={handleSave}
              disabled={saveProject.isPending}
              className="gap-1.5 shrink-0 rounded-[9px] text-[13px] h-9 bg-[#3f2407] hover:bg-[#2b1809]"
            >
              {saveProject.isPending && <TuranLoader variant="spin" size={14} />}
              {t('finance.save')}
            </Button>
          )}
        </div>
      </div>
    </div>
  );
};

function formatMoney(n: number): string {
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(0)} млрд`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(0)} млн`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)} тыс`;
  return String(n);
}

export default ProjectBuilder;

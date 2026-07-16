import { useState, useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';

import PageToolbar, { ToolbarTab, ToolbarChip } from '@/components/layout/PageToolbar';
import Footer from '@/components/public/Footer';
import Reveal from '@/components/public/Reveal';
import { ArrowRight } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { useFinancePrograms } from '@/hooks/finance/useFinancePrograms';
import { buildDetailFromRow } from '@/lib/finance/program-details';
import type { FinanceProgram } from '@/types/finance';

/* ── Filter logic ── */

type FilterGoal = 'all' | 'start' | 'expand' | 'working';
type FilterFarmer = 'all' | 'investor' | 'agri' | 'livestock';

function programMatchesGoal(p: FinanceProgram, goal: FilterGoal): boolean {
  if (goal === 'all') return true;
  if (goal === 'start') return ['zhaylau', 'igilik', 'bereke'].includes(p.id);
  if (goal === 'expand') return ['igilik', 'bereke', 'sybaga', 'import_livestock'].includes(p.id);
  if (goal === 'working') return p.id === 'working_capital';
  return true;
}

function programMatchesFarmer(p: FinanceProgram, farmer: FilterFarmer): boolean {
  if (farmer === 'all') return true;
  const rules = p.eligibility_rules || [];
  if (farmer === 'investor') return rules.length === 0 || p.id === 'zhaylau';
  if (farmer === 'agri') return rules.some(r => r.field === 'is_agri_producer') || ['igilik','bereke'].includes(p.id);
  if (farmer === 'livestock') return rules.some(r => r.field === 'herd_size') || ['igilik','bereke'].includes(p.id);
  return true;
}

/* ── Helpers ── */

const programPurposeTags: Record<string, string[]> = {
  zhaylau: ['infrastructure'],
  igilik: ['livestock', 'import'],
  bereke: ['livestock', 'import'],
  sybaga: ['livestock', 'working'],
  import_livestock: ['import', 'livestock'],
  working_capital: ['working'],
};

function formatMoney(n: number): string {
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(0)} млрд`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(0)} млн`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)} тыс`;
  return String(n);
}

/* ── Component ── */

const ProgramsPage = () => {
  const { t, i18n } = useTranslation();
  const navigate = useNavigate();
  const { data, isLoading } = useFinancePrograms();
  const lang = i18n.language?.startsWith('kk') ? 'kz' : i18n.language || 'ru';

  const [goalFilter, setGoalFilter] = useState<FilterGoal>('all');
  const [farmerFilter, setFarmerFilter] = useState<FilterFarmer>('all');

  const programs = useMemo(() => {
    if (!data?.programs) return [];
    return data.programs.filter(p =>
      programMatchesGoal(p, goalFilter) && programMatchesFarmer(p, farmerFilter)
    );
  }, [data, goalFilter, farmerFilter]);

  const getName = (p: FinanceProgram) => lang === 'kz' ? p.name_kz || p.name_ru : lang === 'en' ? p.name_en || p.name_ru : p.name_ru;
  const getRole = (p: FinanceProgram) => lang === 'kz' ? p.role_in_project_kz || p.role_in_project_ru : p.role_in_project_ru;

  const purposeTagLabel = (tag: string) => {
    const map: Record<string, string> = {
      infrastructure: t('finance.catalog.purposeInfra'),
      livestock: t('finance.catalog.purposeLivestock'),
      working: t('finance.catalog.purposeWorking'),
      import: t('finance.catalog.tagImport'),
    };
    return map[tag] || tag;
  };

  const goalOptions: { value: FilterGoal; label: string }[] = [
    { value: 'all', label: t('finance.catalog.filterAll') },
    { value: 'start', label: t('finance.catalog.goalStart') },
    { value: 'expand', label: t('finance.catalog.goalExpand') },
    { value: 'working', label: t('finance.catalog.goalWorking') },
  ];

  const farmerOptions: { value: FilterFarmer; label: string }[] = [
    { value: 'all', label: t('finance.catalog.filterAll') },
    { value: 'investor', label: t('finance.segments.investor') },
    { value: 'agri', label: t('finance.catalog.farmerAgri') },
    { value: 'livestock', label: t('finance.segments.livestock_farmer') },
  ];

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen" style={{ background: "#fdf6ee" }}>
        <TuranLoader variant="breathe" size={40} />
      </div>
    );
  }

  const hasActiveFilter = goalFilter !== 'all' || farmerFilter !== 'all';

  return (
    <div className="noise-overlay min-h-screen flex flex-col" style={{ background: "#fdf6ee" }}>
      {/* Card hover styles */}
      <style>{`
        .pcard-arrow {
          transition: background 0.3s ease;
        }
        .pcard-arrow svg {
          transform: rotate(-45deg);
          transition: transform 0.3s ease, color 0.3s ease;
        }
        .pcard:hover .pcard-arrow {
          background: #3f2407 !important;
        }
        .pcard:hover .pcard-arrow svg {
          color: #fdf6ee !important;
          transform: rotate(0deg) !important;
        }
        .pcard:hover {
          border-color: rgba(63,36,7,0.15) !important;
        }
        .scrollbar-hide::-webkit-scrollbar { display: none; }
        .scrollbar-hide { -ms-overflow-style: none; scrollbar-width: none; }
        body.filter-sheet-open nav.fixed { opacity: 0; pointer-events: none; transition: opacity 0.2s ease; }
        @keyframes sheet-up {
          from { transform: translateY(100%); }
          to { transform: translateY(0); }
        }
        @keyframes sheet-fade-in {
          from { opacity: 0; }
          to { opacity: 1; }
        }
        .filter-sheet-overlay {
          animation: sheet-fade-in 0.2s ease forwards;
        }
        .filter-sheet-content {
          animation: sheet-up 0.3s cubic-bezier(0.16, 1, 0.3, 1) forwards;
        }
        @keyframes fab-in {
          from { opacity: 0; transform: translateX(-50%) translateY(12px) scale(0.9); }
          to { opacity: 1; transform: translateX(-50%) translateY(0) scale(1); }
        }
        .filter-fab {
          animation: fab-in 0.25s cubic-bezier(0.16, 1, 0.3, 1) forwards;
        }
      `}</style>

      
      <PageToolbar
        actions={
          hasActiveFilter && (
            <button
              onClick={() => { setGoalFilter('all'); setFarmerFilter('all'); }}
              className="text-xs font-medium text-[#2B180A]/45 hover:text-[#E8730C] transition-colors whitespace-nowrap"
            >
              {t('finance.catalog.filterClear', 'Сброс')}
            </button>
          )
        }
      >
        {goalOptions.map(opt => (
          <ToolbarTab
            key={opt.value}
            active={opt.value === goalFilter}
            onClick={() => setGoalFilter(opt.value)}
          >
            {opt.label}
          </ToolbarTab>
        ))}
        <span className="shrink-0 w-px h-4 bg-[#2B180A]/10 mx-2" aria-hidden />
        {farmerOptions.slice(1).map(opt => (
          <ToolbarChip
            key={opt.value}
            active={opt.value === farmerFilter}
            onClick={() => setFarmerFilter(opt.value === farmerFilter ? 'all' : opt.value)}
          >
            {opt.label}
          </ToolbarChip>
        ))}
      </PageToolbar>

      <main className="flex-1 pt-6 md:pt-10 pb-16">
        <div className="mx-auto max-w-[1200px] px-4 md:px-10">

          {/* Page heading */}
          <div className="mb-6 md:mb-10">
            <Reveal>
              <h1 className="font-serif font-light text-[clamp(1.75rem,5vw,2.9rem)] leading-[1.12] tracking-editorial text-foreground mb-2 md:mb-3">
                {t('finance.catalog.title')}
              </h1>
            </Reveal>
            <Reveal delay={100}>
              <p className="text-[14px] md:text-[16px] leading-relaxed max-w-[520px]" style={{ color: "rgba(43,24,10,0.5)" }}>
                {t('finance.catalog.subtitle')}
              </p>
            </Reveal>
          </div>



          {/* Cards */}
          {programs.length === 0 ? (
            <p className="text-center py-16 text-[14px]" style={{ color: "rgba(43,24,10,0.35)" }}>
              {t('finance.catalog.noResults')}
            </p>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3 md:gap-5">
              {programs.map((p, idx) => {
                const isCredit = p.type === 'credit';
                const purposes = programPurposeTags[p.id] || [];
                const detail = buildDetailFromRow(p);
                const badges = detail.heroBadges.slice(0, 3);
                const keyParams = detail.keyParams.slice(0, 3);

                return (
                  <Reveal key={p.id} delay={idx * 50}>
                    <article
                      className="pcard group relative rounded-[16px] cursor-pointer transition-all duration-300 hover:shadow-[0_12px_40px_rgba(43,24,10,0.07)] hover:-translate-y-[2px] overflow-hidden"
                      style={{
                        background: "rgba(255,255,255,0.65)",
                        border: "1px solid rgba(43,24,10,0.07)",
                      }}
                      onClick={() => navigate(`/finance/programs/${p.id}`)}
                    >
                      <div className="p-5 md:p-7">
                        {/* Top row: type + provider + amount */}
                        <div className="flex items-center justify-between mb-4">
                          <div className="flex items-center gap-2">
                            <span
                              className="inline-flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-[0.08em] px-2 py-[3px] rounded-[6px]"
                              style={{
                                background: isCredit ? "rgba(232,115,12,0.08)" : "rgba(107,158,107,0.1)",
                                color: isCredit ? "#E8730C" : "#6B9E6B",
                              }}
                            >
                              {isCredit ? t('finance.typeCredit') : t('finance.typeSubsidy')}
                            </span>
                            {detail.providerShort && (
                              <span
                                className="text-[10px] font-semibold uppercase tracking-[0.06em] px-2 py-[3px] rounded-[6px]"
                                style={{
                                  background: "rgba(43,24,10,0.04)",
                                  color: "rgba(43,24,10,0.4)",
                                }}
                              >
                                {detail.providerShort}
                              </span>
                            )}
                          </div>
                          {p.limits_max > 0 && (
                            <span
                              className="text-[13px] font-semibold tabular-nums"
                              style={{ color: "#2B180A" }}
                            >
                              {t('finance.catalog.upTo')} {formatMoney(p.limits_max)} ₸
                            </span>
                          )}
                        </div>

                        {/* Name */}
                        <h3
                          className="font-serif font-semibold text-[19px] md:text-[22px] leading-[1.2] mb-2.5"
                          style={{ color: "#2B180A" }}
                        >
                          {getName(p)}
                        </h3>

                        {/* Description */}
                        {getRole(p) && (
                          <p
                            className="text-[13px] leading-[1.6] mb-4 line-clamp-2"
                            style={{ color: "rgba(43,24,10,0.5)" }}
                          >
                            {getRole(p)}
                          </p>
                        )}

                        {/* Hero badges — key param pills (hidden on mobile, shown on desktop where bottom bar has more space) */}
                        {badges.length > 0 && (
                          <div className="hidden md:flex flex-wrap gap-1.5 mb-4">
                            {badges.map((b, i) => (
                              <span
                                key={i}
                                className="text-[11px] font-medium px-2.5 py-[4px] rounded-full"
                                style={{
                                  background:
                                    b.style === 'green' ? "rgba(107,158,107,0.12)"
                                    : b.style === 'yellow' ? "rgba(232,115,12,0.08)"
                                    : "rgba(43,24,10,0.04)",
                                  color:
                                    b.style === 'green' ? "#5a8a5a"
                                    : b.style === 'yellow' ? "#c47a20"
                                    : "rgba(43,24,10,0.5)",
                                  border:
                                    b.style === 'green' ? "1px solid rgba(107,158,107,0.2)"
                                    : b.style === 'yellow' ? "1px solid rgba(232,115,12,0.15)"
                                    : "1px solid rgba(43,24,10,0.06)",
                                }}
                              >
                                {b.text}
                              </span>
                            ))}
                          </div>
                        )}
                      </div>

                      {/* Bottom bar — key stats + tags + arrow */}
                      <div
                        className="px-5 md:px-7 py-3.5 md:py-4 flex items-center justify-between gap-4"
                        style={{ background: "rgba(43,24,10,0.025)", borderTop: "1px solid rgba(43,24,10,0.05)" }}
                      >
                        {/* Key params — compact stats */}
                        {keyParams.length > 0 ? (
                          <div className="flex items-center gap-3 md:gap-5 min-w-0">
                            {keyParams.map((kp, i) => (
                              <div key={i} className="min-w-0">
                                <div
                                  className="font-serif font-semibold text-[15px] md:text-[17px] leading-none truncate"
                                  style={{ color: "#2B180A" }}
                                >
                                  {kp.value}
                                </div>
                                <div
                                  className="text-[10px] mt-0.5 truncate"
                                  style={{ color: "rgba(43,24,10,0.35)" }}
                                >
                                  {kp.label}
                                </div>
                              </div>
                            ))}
                          </div>
                        ) : (
                          <div className="flex flex-wrap gap-1.5">
                            {purposes.map(tag => (
                              <span
                                key={tag}
                                className="text-[10px] font-medium px-2 py-[2px] rounded-[6px]"
                                style={{
                                  background: "rgba(43,24,10,0.04)",
                                  color: "rgba(43,24,10,0.4)",
                                }}
                              >
                                {purposeTagLabel(tag)}
                              </span>
                            ))}
                          </div>
                        )}

                        {/* Arrow */}
                        <div
                          className="pcard-arrow w-11 h-11 md:w-9 md:h-9 rounded-full flex items-center justify-center shrink-0"
                          style={{ background: "rgba(43,24,10,0.06)" }}
                        >
                          <ArrowRight
                            size={16}
                            strokeWidth={2}
                            style={{ color: "rgba(43,24,10,0.3)" }}
                          />
                        </div>
                      </div>
                    </article>
                  </Reveal>
                );
              })}
            </div>
          )}
        </div>
      </main>

      <Footer />
    </div>
  );
};

export default ProgramsPage;

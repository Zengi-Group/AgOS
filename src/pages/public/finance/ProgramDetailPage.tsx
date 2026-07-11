import { useState, useMemo, useEffect, useCallback, useRef } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate, useParams, Link } from 'react-router-dom';

import Reveal from '@/components/public/Reveal';

import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Slider } from '@/components/ui/slider';
import {
  Accordion, AccordionContent, AccordionItem, AccordionTrigger,
} from '@/components/ui/accordion';
import {
  ArrowLeft, ArrowRight, Info, Send, Share2, FileDown, ArrowLeftRight,
  CheckCircle2, XCircle, AlertTriangle, Calculator, FileText,
  HelpCircle, ClipboardList, Layers, Shield, Footprints,
} from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { useFinancePrograms } from '@/hooks/finance/useFinancePrograms';
import { supabase } from '@/lib/supabase';
import { toast } from 'sonner';
import type { FinanceProgram, ProjectInputs } from '@/types/finance';
import { buildDetailFromRow, computeWizardScoreFromRules, type WizardRule } from '@/lib/finance/program-details';

/* ─── Constants ─── */
const C = {
  text1: '#2B180A',
  text2: 'rgba(43,24,10,0.65)',
  dim: 'rgba(43,24,10,0.35)',
  blockBg: 'rgba(255,255,255,0.25)',
  blockBorder: 'rgba(43,24,10,0.08)',
  pageBg: '#fdf6ee',
};

/* ─── Section nav config ─── */
const NAV_SECTIONS = [
  { id: 'overview', label: 'Обзор' },
  { id: 'eligibility', label: 'Кому подходит' },
  { id: 'target-use', label: 'Целевое использование' },
  { id: 'calculator', label: 'Калькулятор' },
  { id: 'conditions', label: 'Условия' },
  { id: 'documents', label: 'Документы' },
  { id: 'how-to-apply', label: 'Как подать' },
  { id: 'faq', label: 'Вопросы' },
] as const;

/* ─── Helpers ─── */
function calcPayment(amount: number, years: number, rate: number): number {
  const mo = rate / 100 / 12;
  const n = years * 12;
  if (mo === 0) return Math.round(amount / n);
  return Math.round(amount * mo * Math.pow(1 + mo, n) / (Math.pow(1 + mo, n) - 1));
}

function fmtMoney(v: number): string {
  return v.toLocaleString('ru-RU') + ' ₸';
}

function getName(p: FinanceProgram, lang: string) {
  return lang === 'kz' ? p.name_kz || p.name_ru : lang === 'en' ? p.name_en || p.name_ru : p.name_ru;
}

/* ─── Section Block (same pattern as Startups) ─── */
function SectionBlock({ children, className = '', id }: { children: React.ReactNode; className?: string; id?: string }) {
  return (
    <div
      id={id}
      className={`rounded-[14px] px-5 py-5 md:px-6 md:py-6 ${className}`}
      style={{ background: C.blockBg, border: `1px solid ${C.blockBorder}` }}
    >
      {children}
    </div>
  );
}

/* ─── Section Title ─── */
function SectionTitle({ icon, children }: { icon?: React.ReactNode; children: React.ReactNode }) {
  return (
    <h2 className="font-serif font-semibold text-[18px] md:text-[20px] flex items-center gap-2.5 mb-4" style={{ color: C.text1 }}>
      {icon && <span className="text-[#786758]">{icon}</span>}
      {children}
    </h2>
  );
}

/* ─────────────────── MAIN ─────────────────── */
const ProgramDetailPage = () => {
  const { id } = useParams<{ id: string }>();
  const { i18n } = useTranslation();
  const navigate = useNavigate();
  const { data, isLoading } = useFinancePrograms();
  const lang = i18n.language?.startsWith('kk') ? 'kz' : i18n.language || 'ru';

  const program = useMemo(() => data?.programs.find(p => p.id === id), [data, id]);
  const detail = useMemo(() => program ? buildDetailFromRow(program) : undefined, [program]);

  // Wizard rules from DB
  const [wizardRules, setWizardRules] = useState<WizardRule[]>([]);
  useEffect(() => {
    if (!id) return;
    supabase.from('finance_wizard_rules' as any).select('*').eq('program_id', id).order('order_index')
      .then(({ data: rules }) => { if (rules) setWizardRules(rules as any as WizardRule[]); });
  }, [id]);

  // Personalized profile
  const profile = useMemo<ProjectInputs | null>(() => {
    try {
      const raw = localStorage.getItem('finance_profile');
      return raw ? JSON.parse(raw) as ProjectInputs : null;
    } catch { return null; }
  }, []);

  const wizard = useMemo(() => {
    if (!wizardRules.length || !profile) return null;
    return computeWizardScoreFromRules(wizardRules, profile);
  }, [wizardRules, profile]);

  const clearProfile = () => { localStorage.removeItem('finance_profile'); window.location.reload(); };

  // Calculator state
  const [loanAmount, setLoanAmount] = useState([20]);
  const [loanTerm, setLoanTerm] = useState([5]);
  const [loanRate, setLoanRate] = useState([7]);

  useEffect(() => {
    if (detail) {
      setLoanAmount([detail.calc.defaultAmount]);
      setLoanTerm([detail.calc.defaultTerm]);
      setLoanRate([detail.calc.defaultRate]);
    }
  }, [detail]);

  const monthlyPayment = useMemo(
    () => calcPayment((loanAmount[0] ?? 0) * 1_000_000, loanTerm[0] ?? 0, loanRate[0] ?? 0),
    [loanAmount, loanTerm, loanRate],
  );

  const isSubsidy = detail?.calc.maxRate === 0;

  // Consultation
  const [showConsultation, setShowConsultation] = useState(false);
  const [consultForm, setConsultForm] = useState({ name: '', phone: '', message: '' });
  const [submitting, setSubmitting] = useState(false);

  // Sticky footer + scroll-spy + key params sticky
  const [showSticky, setShowSticky] = useState(false);
  const [activeSection, setActiveSection] = useState('overview');
  const [paramsCompact, setParamsCompact] = useState(false);
  const keyParamsRef = useRef<HTMLDivElement>(null);
  const navRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const onScroll = () => {
      setShowSticky(window.scrollY > 500);

      // Key params compact mode: when scrolled past the key params grid
      if (keyParamsRef.current) {
        const rect = keyParamsRef.current.getBoundingClientRect();
        setParamsCompact(rect.bottom < 60);
      }

      // Scroll-spy: find which section is in view
      const navH = 100; // nav bar height offset
      for (let i = NAV_SECTIONS.length - 1; i >= 0; i--) {
        const el = document.getElementById(NAV_SECTIONS[i]!.id);
        if (el && el.getBoundingClientRect().top <= navH + 20) {
          setActiveSection(NAV_SECTIONS[i]!.id);
          break;
        }
      }
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  const goToBuilder = useCallback(() => {
    const params = new URLSearchParams();
    if (program) {
      params.set('program', program.id);
      const goalMap: Record<string, string> = { zhaylau: 'start_farm', bereke: 'add_livestock', sybaga: 'increase_herd', working_capital: 'working_capital', import_livestock: 'expand_farm' };
      if (goalMap[program.id]) params.set('goal', goalMap[program.id]!);
    }
    navigate(`/finance/build?${params.toString()}`);
  }, [program, navigate]);

  const handleConsultSubmit = async () => {
    if (!consultForm.name.trim() || !consultForm.phone.trim()) { toast.error('Заполните имя и телефон'); return; }
    setSubmitting(true);
    try {
      const { error } = await supabase.from('registration_applications').insert({
        full_name: consultForm.name.trim(), phone: consultForm.phone.trim(),
        role: 'consultation', how_heard: `finance_program:${id}`,
        farm_name: consultForm.message.trim() || null,
      });
      if (error) throw error;
      supabase.functions.invoke('create-bitrix-lead', {
        body: { full_name: consultForm.name.trim(), phone: consultForm.phone.trim(), role: 'consultation', company_name: program ? `Финансовая программа: ${getName(program, lang)}` : '' },
      }).catch(() => {});
      toast.success('Заявка отправлена! Менеджер свяжется с вами.');
      setShowConsultation(false);
      setConsultForm({ name: '', phone: '', message: '' });
    } catch { toast.error('Ошибка при отправке. Попробуйте позже.'); }
    finally { setSubmitting(false); }
  };

  const scrollToSection = (id: string) => {
    const el = document.getElementById(id);
    if (el) {
      const top = el.getBoundingClientRect().top + window.scrollY - 56;
      window.scrollTo({ top, behavior: 'smooth' });
    }
  };
  const scrollToCalc = () => scrollToSection('calculator');

  // Similar programs
  const similarPrograms = useMemo(() => {
    if (!detail || !data) return [];
    return detail.similarIds
      .map(sid => {
        const p = data.programs.find(pr => pr.id === sid);
        if (!p) return null;
        const sd = buildDetailFromRow(p);
        return { id: sid, name: getName(p, lang), provider: sd.providerShort, desc: sd.heroDesc?.slice(0, 80), badges: sd.heroBadges.slice(0, 3) };
      })
      .filter(Boolean) as { id: string; name: string; provider: string; desc: string; badges: { text: string; style: string }[] }[];
  }, [detail, data, lang]);

  /* ─── Loading ─── */
  if (isLoading) {
    return (
      <div className="noise-overlay" style={{ background: C.pageBg, minHeight: '100vh' }}>
        <main className="mx-auto max-w-[1200px] px-5 md:px-10 pt-8 pb-16">
          <div className="h-6 w-48 bg-[rgba(43,24,10,0.06)] rounded mb-8 animate-pulse" />
          <div className="h-[240px] w-full bg-[rgba(43,24,10,0.04)] rounded-2xl mb-6 animate-pulse" />
          <div className="h-8 w-2/3 bg-[rgba(43,24,10,0.06)] rounded mb-3 animate-pulse" />
          <div className="h-4 w-3/4 bg-[rgba(43,24,10,0.04)] rounded mb-2 animate-pulse" />
        </main>
      </div>
    );
  }

  if (!program || !detail) {
    return (
      <div className="noise-overlay" style={{ background: C.pageBg, minHeight: '100vh' }}>
        <main className="mx-auto max-w-[1200px] px-5 md:px-10 pt-8 pb-16 text-center">
          <p style={{ color: C.dim }}>Программа не найдена</p>
          <Link to="/finance/programs" className="text-sm font-medium underline underline-offset-4 mt-4 inline-block" style={{ color: '#E07A34' }}>
            Вернуться к каталогу
          </Link>
        </main>
      </div>
    );
  }

  const d = detail;

  return (
    <div className="noise-overlay" style={{ background: C.pageBg, minHeight: '100vh' }}>

      {/* ══════ STICKY SECTION NAV ══════ */}
      <nav
        ref={navRef}
        className="sticky top-0 z-50 border-b"
        style={{
          backgroundColor: 'rgba(253,246,238,0.95)',
          backdropFilter: 'blur(16px)',
          WebkitBackdropFilter: 'blur(16px)',
          borderColor: 'rgba(43,24,10,0.07)',
        }}
      >
        <div className="mx-auto max-w-[1200px] px-5 md:px-10">
          {/* Compact key params (visible only when scrolled past params grid) */}
          <div
            className="overflow-hidden transition-all duration-300"
            style={{ maxHeight: paramsCompact ? 44 : 0, opacity: paramsCompact ? 1 : 0 }}
          >
            <div className="flex items-center gap-4 py-2 overflow-x-auto scrollbar-hide">
              <Link
                to="/finance/programs"
                className="flex items-center gap-1 text-[13px] font-medium shrink-0 transition-opacity hover:opacity-70"
                style={{ color: C.dim }}
              >
                <ArrowLeft size={14} />
              </Link>
              <span className="text-[14px] font-semibold font-serif shrink-0 truncate max-w-[180px]" style={{ color: C.text1 }}>
                {(d.heroTitle.split('—')[0] ?? '').trim()}
              </span>
              <div className="w-px h-4 shrink-0" style={{ background: C.blockBorder }} />
              {d.keyParams.slice(0, 4).map((p, i) => (
                <div key={i} className="flex items-center gap-1.5 shrink-0">
                  <span className="text-[11px]" style={{ color: C.dim }}>{p.label}</span>
                  <span
                    className="text-[13px] font-semibold font-serif"
                    style={{ color: p.color === 'green' ? '#2E7D3A' : p.color === 'yellow' ? '#b8860b' : C.text1 }}
                  >
                    {p.value}
                  </span>
                </div>
              ))}
            </div>
          </div>
          {/* Section links */}
          <div className="flex overflow-x-auto scrollbar-hide gap-0">
            {NAV_SECTIONS.map((s) => (
              <button
                key={s.id}
                onClick={() => scrollToSection(s.id)}
                className="shrink-0 px-3 py-3 text-[13px] md:text-[14px] font-medium border-b-2 transition-all duration-200 bg-transparent cursor-pointer"
                style={{
                  color: activeSection === s.id ? C.text1 : 'rgba(43,24,10,0.45)',
                  borderColor: activeSection === s.id ? '#2B180A' : 'transparent',
                }}
              >
                {s.label}
              </button>
            ))}
          </div>
        </div>
      </nav>

      <main className="mx-auto max-w-[1200px] px-5 md:px-10 pt-6 pb-20">

        {/* ══════ BREADCRUMB ══════ */}
        <Reveal delay={0}>
          <Link
            to="/finance/programs"
            className="inline-flex items-center gap-1.5 text-sm font-medium mb-6 transition-opacity hover:opacity-70"
            style={{ color: C.dim }}
          >
            <ArrowLeft size={16} />
            Каталог программ
          </Link>
        </Reveal>

        {/* ══════ HERO CARD ══════ */}
        <Reveal delay={50}>
          <div id="overview" className="relative rounded-[20px] overflow-hidden mb-8" style={{ background: d.heroColor }}>
            {/* Decorative circles */}
            <div className="absolute -right-16 -top-16 w-56 h-56 rounded-full bg-white/[0.03]" />
            <div className="absolute right-10 -bottom-20 w-40 h-40 rounded-full bg-white/[0.025]" />
            <div className="absolute left-1/2 top-0 w-[600px] h-[600px] rounded-full bg-white/[0.015] -translate-x-1/2 -translate-y-[75%]" />

            <div className="relative px-6 py-8 md:px-10 md:py-10">
              {/* Provider tag */}
              <div className="flex items-center justify-between mb-5">
                <p className="text-[11px] font-medium tracking-[0.1em] uppercase flex items-center gap-2" style={{ color: 'rgba(168,201,168,0.9)' }}>
                  <span className="w-5 h-px" style={{ background: 'rgba(168,201,168,0.5)' }} />
                  {d.provider}
                </p>
                <div className="w-11 h-11 rounded-xl bg-white/10 border border-white/15 flex items-center justify-center text-[11px] text-white/60 font-medium tracking-wide">
                  {d.providerShort}
                </div>
              </div>

              {/* Title */}
              <h1
                className="font-serif font-normal text-[clamp(1.5rem,4vw,2.25rem)] leading-[1.15] tracking-editorial text-white mb-3"
              >
                {d.heroTitle}
              </h1>

              {/* Description */}
              <p className="text-[15px] md:text-[16px] leading-relaxed max-w-[620px] mb-6" style={{ color: 'rgba(168,201,168,0.85)' }}>
                {d.heroDesc}
              </p>

              {/* Badges */}
              <div className="flex flex-wrap gap-2 mb-7">
                {d.heroBadges.map((b, i) => {
                  const styles: Record<string, React.CSSProperties> = {
                    green: { background: 'rgba(126,200,126,.15)', color: '#a8e6a8', borderColor: 'rgba(126,200,126,.25)' },
                    yellow: { background: 'rgba(245,200,66,.12)', color: '#f5d878', borderColor: 'rgba(245,200,66,.2)' },
                    white: { background: 'rgba(255,255,255,.08)', color: 'rgba(255,255,255,.6)', borderColor: 'rgba(255,255,255,.12)' },
                  };
                  return (
                    <span key={i} className="text-[12px] px-3 py-1 rounded-full font-medium border" style={styles[b.style] || styles.white}>
                      {b.text}
                    </span>
                  );
                })}
              </div>

              {/* CTA buttons */}
              <div className="flex gap-3 flex-wrap">
                <button
                  className="text-[14px] font-medium px-6 py-3 rounded-[13px] border-none cursor-pointer transition-all duration-300 hover:brightness-[0.92]"
                  style={{ background: '#f5c842', color: '#1a1a1a' }}
                  onClick={() => setShowConsultation(true)}
                >
                  Получить консультацию
                </button>
                {!isSubsidy && (
                  <button
                    className="text-[14px] px-6 py-3 rounded-[13px] cursor-pointer border transition-all duration-300 hover:bg-white/20"
                    style={{ background: 'rgba(255,255,255,.08)', color: '#fff', borderColor: 'rgba(255,255,255,.2)' }}
                    onClick={scrollToCalc}
                  >
                    Рассчитать платёж
                  </button>
                )}
              </div>
            </div>
          </div>
        </Reveal>

        {/* ══════ KEY PARAMS GRID ══════ */}
        <Reveal delay={100}>
          <div ref={keyParamsRef} className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mb-8">
            {d.keyParams.map((p, i) => (
              <div key={i} className="rounded-[14px] px-4 py-3.5" style={{ background: C.blockBg, border: `1px solid ${C.blockBorder}` }}>
                <div className="text-[11px] mb-1" style={{ color: C.dim }}>{p.label}</div>
                <div
                  className="text-[18px] font-semibold leading-tight font-serif"
                  style={{ color: p.color === 'green' ? '#2E7D3A' : p.color === 'yellow' ? '#b8860b' : C.text1 }}
                >
                  {p.value}
                </div>
                {p.sub && <div className="text-[11px] mt-0.5" style={{ color: C.dim }}>{p.sub}</div>}
              </div>
            ))}
          </div>
        </Reveal>

        {/* ══════ WIZARD / ELIGIBILITY CHECK ══════ */}
        <Reveal delay={150}>
          {wizard && profile ? (
            <SectionBlock className="mb-8">
              <div className="flex items-start justify-between gap-4 mb-4 flex-wrap">
                <div className="flex items-center gap-3">
                  <div className={`w-10 h-10 rounded-full flex items-center justify-center shrink-0 ${
                    wizard.verdict === 'fit' ? 'bg-[#EAF3DE]' : wizard.verdict === 'partial' ? 'bg-[#FFF3E0]' : 'bg-[#FCEBEB]'
                  }`}>
                    {wizard.verdict === 'fit' ? <CheckCircle2 className="w-5 h-5 text-[#2E7D3A]" /> :
                     wizard.verdict === 'partial' ? <AlertTriangle className="w-5 h-5 text-[#b8860b]" /> :
                     <XCircle className="w-5 h-5 text-[#c62828]" />}
                  </div>
                  <div>
                    <div className="text-[15px] font-semibold font-serif" style={{ color: C.text1 }}>
                      {wizard.verdict === 'fit' ? 'Программа подходит вашему хозяйству' :
                       wizard.verdict === 'partial' ? 'Частично подходит — есть нюансы' :
                       'Программа пока не подходит'}
                    </div>
                    <div className="text-[13px] mt-0.5" style={{ color: C.dim }}>
                      Совпадение: {wizard.score} из {wizard.total} критериев
                    </div>
                  </div>
                </div>
                <button className="text-[12px] underline cursor-pointer bg-transparent border-none" style={{ color: C.dim }} onClick={clearProfile}>
                  Сбросить анкету
                </button>
              </div>
              <div className="space-y-2">
                {wizard.labels?.map((label, i) => (
                  <div key={i} className="flex items-center gap-3 text-[14px] py-1.5 border-b last:border-b-0" style={{ borderColor: C.blockBorder }}>
                    {wizard.passed[i]
                      ? <CheckCircle2 className="w-4 h-4 text-[#2E7D3A] shrink-0" />
                      : <XCircle className="w-4 h-4 text-[#c62828] shrink-0" />}
                    <span style={{ color: wizard.passed[i] ? C.text1 : C.dim }}>{label}</span>
                  </div>
                ))}
              </div>
              {wizard.verdict !== 'fit' && (
                <button
                  className="text-[14px] font-medium px-5 py-2.5 rounded-[13px] border-none cursor-pointer text-white mt-4 transition-all duration-300 hover:brightness-[0.92]"
                  style={{ background: '#3f2407' }}
                  onClick={goToBuilder}
                >
                  Собрать полный проект →
                </button>
              )}
            </SectionBlock>
          ) : (
            <div
              className="rounded-[14px] px-5 py-5 md:px-6 flex items-center justify-between gap-4 flex-wrap mb-8"
              style={{ background: '#f1e7dc', border: `1px solid rgba(43,24,10,0.06)` }}
            >
              <div className="flex items-center gap-3">
                <div className="icon-box icon-box--sm">
                  <ArrowRight />
                </div>
                <div>
                  <div className="text-[15px] font-medium" style={{ color: C.text1 }}>
                    Узнайте, подходит ли программа вашему хозяйству
                  </div>
                  <div className="text-[13px] mt-0.5" style={{ color: C.dim }}>
                    Пройдите анкету за 2 минуты — проверим критерии и подберём лучшие варианты
                  </div>
                </div>
              </div>
              <button
                className="text-[14px] font-medium px-5 py-2.5 rounded-[13px] border-none cursor-pointer text-white whitespace-nowrap transition-all duration-300 hover:brightness-[0.92]"
                style={{ background: '#3f2407' }}
                onClick={goToBuilder}
              >
                Пройти анкету
              </button>
            </div>
          )}
        </Reveal>

        {/* ══════ INFO NOTICE ══════ */}
        {d.infoNotice && (
          <Reveal delay={175}>
            <div
              className="flex gap-3 rounded-[14px] px-5 py-4 text-[14px] leading-relaxed mb-8"
              style={{ background: 'rgba(43,24,10,0.03)', border: `1px solid ${C.blockBorder}`, color: C.text2 }}
            >
              <Info className="w-5 h-5 shrink-0 mt-0.5" style={{ color: C.dim }} />
              <span>{d.infoNotice}</span>
            </div>
          </Reveal>
        )}

        {/* ══════ ELIGIBILITY: WHO IT'S FOR ══════ */}
        <Reveal delay={200}>
          <SectionBlock className="mb-8" id="eligibility">
            <SectionTitle icon={<Shield size={20} />}>Кому подходит / кому не подходит</SectionTitle>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
              {/* Fits */}
              <div>
                <div className="flex items-center gap-2 mb-3">
                  <div className="w-2 h-2 rounded-full bg-[#2E7D3A]" />
                  <span className="text-[13px] font-medium" style={{ color: '#1E5C2A' }}>Подходит, если</span>
                </div>
                <div className="space-y-2">
                  {d.eligibleItems.map((item, i) => (
                    <div key={i} className="flex items-start gap-2.5 text-[14px] leading-relaxed" style={{ color: '#3B6D11' }}>
                      <CheckCircle2 className="w-4 h-4 text-[#2E7D3A] shrink-0 mt-0.5" />
                      {item}
                    </div>
                  ))}
                </div>
              </div>
              {/* Doesn't fit */}
              <div>
                <div className="flex items-center gap-2 mb-3">
                  <div className="w-2 h-2 rounded-full bg-[#c62828]" />
                  <span className="text-[13px] font-medium" style={{ color: '#791F1F' }}>Не подходит, если</span>
                </div>
                <div className="space-y-2">
                  {d.notEligibleItems.map((item, i) => (
                    <div key={i} className="flex items-start gap-2.5 text-[14px] leading-relaxed" style={{ color: '#791F1F' }}>
                      <XCircle className="w-4 h-4 text-[#c62828] shrink-0 mt-0.5" />
                      {item}
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </SectionBlock>
        </Reveal>

        {/* ══════ TARGET USE ══════ */}
        <Reveal delay={250}>
          <SectionBlock className="mb-8" id="target-use">
            <SectionTitle icon={<Layers size={20} />}>Целевое использование</SectionTitle>

            <div className="mb-5">
              <div className="text-[12px] font-medium tracking-wide uppercase mb-3" style={{ color: C.dim }}>
                Что покрывает
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                {d.coveredItems.map((item, i) => (
                  <div key={i} className="flex items-start gap-2.5 rounded-xl px-4 py-2.5 text-[14px] leading-relaxed" style={{ background: '#EAF3DE', color: '#27500A' }}>
                    <CheckCircle2 className="w-4 h-4 text-[#2E7D3A] shrink-0 mt-0.5" />
                    {item}
                  </div>
                ))}
              </div>
            </div>

            <div className="pt-4" style={{ borderTop: `1px solid ${C.blockBorder}` }}>
              <div className="text-[12px] font-medium tracking-wide uppercase mb-3" style={{ color: C.dim }}>
                Не покрывает
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                {d.notCoveredItems.map((item, i) => (
                  <div key={i} className="flex items-start gap-2.5 rounded-xl px-4 py-2.5 text-[14px] leading-relaxed" style={{ background: '#FCEBEB', color: '#791F1F' }}>
                    <XCircle className="w-4 h-4 text-[#c62828] shrink-0 mt-0.5" />
                    {item}
                  </div>
                ))}
              </div>
            </div>
          </SectionBlock>
        </Reveal>

        {/* ══════ CALCULATOR ══════ */}
        {!isSubsidy && (
          <Reveal delay={300}>
            <SectionBlock className="mb-8" >
              <div id="calculator">
                <SectionTitle icon={<Calculator size={20} />}>Калькулятор платежа</SectionTitle>

                {profile ? (
                  <div className="flex items-center gap-2.5 rounded-xl px-4 py-3 text-[13px] mb-5" style={{ background: '#EAF3DE', color: '#27500A' }}>
                    <CheckCircle2 className="w-4 h-4 text-[#2E7D3A] shrink-0" />
                    <span>Калькулятор настроен под ваш профиль: цель — {profile.goal_type === 'start_farm' ? 'старт' : profile.goal_type === 'add_livestock' ? 'закупка скота' : profile.goal_type === 'increase_herd' ? 'увеличение стада' : profile.goal_type === 'working_capital' ? 'оборотка' : 'расширение'}, поголовье {profile.target_herd_size} гол.</span>
                  </div>
                ) : (
                  <div className="flex items-center justify-between gap-3 flex-wrap rounded-xl px-4 py-3 mb-5" style={{ background: '#f1e7dc' }}>
                    <span className="text-[13px]" style={{ color: C.text2 }}>Пройдите анкету — мы предзаполним калькулятор под ваши цели</span>
                    <button className="text-[13px] font-medium px-4 py-2 rounded-[13px] border-none cursor-pointer text-white whitespace-nowrap transition-all duration-300 hover:brightness-[0.92]" style={{ background: '#3f2407' }} onClick={goToBuilder}>
                      Пройти →
                    </button>
                  </div>
                )}

                <div className="rounded-xl px-5 py-5 space-y-5" style={{ background: 'rgba(43,24,10,0.02)', border: `1px solid ${C.blockBorder}` }}>
                  {/* Loan amount */}
                  <div>
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-[14px]" style={{ color: C.text2 }}>Сумма займа</span>
                      <span className="text-[16px] font-semibold tabular-nums" style={{ color: C.text1 }}>{loanAmount[0]} 000 000 ₸</span>
                    </div>
                    <Slider value={loanAmount} onValueChange={setLoanAmount} min={d.calc.minAmount} max={d.calc.maxAmount} step={1} className="w-full" />
                    <div className="flex justify-between text-[12px] mt-1.5" style={{ color: C.dim }}><span>{d.calc.minAmount} млн</span><span>{d.calc.maxAmount} млн ₸</span></div>
                  </div>

                  {/* Term */}
                  <div>
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-[14px]" style={{ color: C.text2 }}>Срок кредита</span>
                      <span className="text-[16px] font-semibold tabular-nums" style={{ color: C.text1 }}>{loanTerm[0] ?? 0} {(loanTerm[0] ?? 0) === 1 ? 'год' : (loanTerm[0] ?? 0) < 5 ? 'года' : 'лет'}</span>
                    </div>
                    <Slider value={loanTerm} onValueChange={setLoanTerm} min={d.calc.minTerm} max={d.calc.maxTerm} step={1} className="w-full" />
                    <div className="flex justify-between text-[12px] mt-1.5" style={{ color: C.dim }}><span>{d.calc.minTerm} год</span><span>{d.calc.maxTerm} лет</span></div>
                  </div>

                  {/* Rate */}
                  <div>
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-[14px]" style={{ color: C.text2 }}>Ставка</span>
                      <span className="text-[16px] font-semibold tabular-nums" style={{ color: C.text1 }}>{loanRate[0]}%</span>
                    </div>
                    <Slider value={loanRate} onValueChange={setLoanRate} min={d.calc.minRate} max={d.calc.maxRate} step={1} className="w-full" />
                    <div className="flex justify-between text-[12px] mt-1.5" style={{ color: C.dim }}><span>{d.calc.minRate}% (с субсидией)</span><span>{d.calc.maxRate}% (рыночная)</span></div>
                  </div>

                  {/* Result */}
                  <div className="rounded-xl px-5 py-4 flex justify-between items-center gap-3 flex-wrap" style={{ background: d.heroColor }}>
                    <div>
                      <div className="text-[13px] text-white/80">Примерный ежемесячный платёж</div>
                      <div className="text-[11px] mt-0.5 text-white/50">аннуитетный, без льготного периода</div>
                    </div>
                    <div className="text-[22px] font-semibold text-white tabular-nums">{fmtMoney(monthlyPayment)}</div>
                  </div>
                </div>

                <p className="text-[12px] mt-3" style={{ color: C.dim }}>
                  Расчёт ориентировочный. Точные условия уточняются в банке-партнёре.
                </p>
              </div>
            </SectionBlock>
          </Reveal>
        )}

        {/* ══════ CONDITIONS TABLE ══════ */}
        <Reveal delay={350}>
          <SectionBlock className="mb-8" id="conditions">
            <SectionTitle icon={<ClipboardList size={20} />}>Детальные условия финансирования</SectionTitle>
            <div className="divide-y" style={{ borderColor: C.blockBorder }}>
              {d.conditions.map(([label, value], i) => (
                <div key={i} className="flex gap-4 py-3.5 first:pt-0 last:pb-0">
                  <span className="text-[14px] w-[45%] shrink-0" style={{ color: C.dim }}>{label}</span>
                  <span className="text-[14px] font-medium" style={{ color: C.text1 }}>{value}</span>
                </div>
              ))}
            </div>
          </SectionBlock>
        </Reveal>

        {/* ══════ DOCUMENTS ══════ */}
        <Reveal delay={400}>
          <SectionBlock className="mb-8" id="documents">
            <SectionTitle icon={<FileText size={20} />}>Необходимые документы</SectionTitle>
            <div className="space-y-2">
              {d.documents.map((doc, i) => (
                <div key={i} className="flex items-center gap-3 rounded-xl px-4 py-3 text-[14px]" style={{ background: 'rgba(43,24,10,0.02)', border: `1px solid ${C.blockBorder}` }}>
                  <span className="text-[13px] font-medium w-7 text-center shrink-0" style={{ color: C.dim }}>{i + 1}</span>
                  <span style={{ color: C.text1 }}>{doc.name}</span>
                  {doc.required && (
                    <span className="ml-auto text-[11px] px-2 py-0.5 rounded-full" style={{ background: '#EAF3DE', color: '#2E7D3A' }}>
                      обязательно
                    </span>
                  )}
                </div>
              ))}
            </div>
            {profile ? (
              <div className="mt-5 pt-4 flex items-center gap-2.5 text-[13px]" style={{ borderTop: `1px solid ${C.blockBorder}`, color: '#27500A' }}>
                <CheckCircle2 className="w-4 h-4 text-[#2E7D3A] shrink-0" />
                Анкета заполнена. Подготовьте документы из списка и подайте заявку.
              </div>
            ) : (
              <div className="mt-5 pt-4 flex items-center justify-between gap-3 flex-wrap" style={{ borderTop: `1px solid ${C.blockBorder}` }}>
                <span className="text-[13px]" style={{ color: C.dim }}>Пройдите анкету — узнайте что уже есть, а что нужно подготовить</span>
                <button className="text-[13px] font-medium px-4 py-2 rounded-[13px] border-none cursor-pointer text-white transition-all duration-300 hover:brightness-[0.92]" style={{ background: '#3f2407' }} onClick={goToBuilder}>
                  Пройти анкету →
                </button>
              </div>
            )}
          </SectionBlock>
        </Reveal>

        {/* ══════ HOW TO APPLY ══════ */}
        <Reveal delay={450}>
          <SectionBlock className="mb-8" id="how-to-apply">
            <SectionTitle icon={<Footprints size={20} />}>Как подать заявку</SectionTitle>
            <div className="relative">
              {d.steps.map((step, i) => (
                <div key={i} className="flex gap-4 relative pb-6 last:pb-0">
                  {/* Vertical connector */}
                  {i < d.steps.length - 1 && (
                    <div className="absolute left-[15px] top-[36px] w-[2px] bottom-0" style={{ background: 'rgba(43,24,10,0.06)' }} />
                  )}
                  {/* Step number */}
                  <div className="w-[30px] h-[30px] rounded-full flex items-center justify-center text-[13px] font-semibold text-white shrink-0 relative z-10" style={{ background: d.heroColor }}>
                    {i + 1}
                  </div>
                  <div className="pt-0.5 flex-1">
                    <div className="text-[15px] font-medium mb-1" style={{ color: C.text1 }}>{step.title}</div>
                    <div className="text-[14px] leading-relaxed mb-1.5" style={{ color: C.text2 }}>{step.desc}</div>
                    <span className="inline-block text-[12px] rounded-full px-3 py-0.5" style={{ background: 'rgba(43,24,10,0.04)', color: C.dim }}>
                      {step.time}
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </SectionBlock>
        </Reveal>

        {/* ══════ FAQ ══════ */}
        <Reveal delay={500}>
          <SectionBlock className="mb-8" id="faq">
            <SectionTitle icon={<HelpCircle size={20} />}>Частые вопросы</SectionTitle>
            <Accordion type="single" collapsible>
              {d.faq.map((faq, i) => (
                <AccordionItem key={i} value={`faq-${i}`} className={i < d.faq.length - 1 ? '' : 'border-none'} style={{ borderColor: C.blockBorder }}>
                  <AccordionTrigger className="text-[15px] font-medium py-4 hover:no-underline" style={{ color: C.text1 }}>
                    {faq.q}
                  </AccordionTrigger>
                  <AccordionContent className="text-[14px] leading-relaxed pb-4" style={{ color: C.text2 }}>
                    {faq.a}
                  </AccordionContent>
                </AccordionItem>
              ))}
            </Accordion>
          </SectionBlock>
        </Reveal>

        {/* ══════ SIMILAR PROGRAMS ══════ */}
        {similarPrograms.length > 0 && (
          <Reveal delay={550}>
            <div className="mb-8">
              <h2 className="font-serif font-semibold text-[18px] md:text-[20px] mb-5" style={{ color: C.text1 }}>
                Похожие программы
              </h2>
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                {similarPrograms.map((sp) => (
                  <div
                    key={sp.id}
                    className="rounded-[14px] px-5 py-4 cursor-pointer transition-all duration-300 hover:shadow-md hover:translate-y-[-2px]"
                    style={{ background: C.blockBg, border: `1px solid ${C.blockBorder}` }}
                    onClick={() => navigate(`/finance/programs/${sp.id}`)}
                  >
                    <div className="text-[11px] font-medium tracking-wide uppercase mb-2" style={{ color: C.dim }}>{sp.provider}</div>
                    <div className="font-serif font-semibold text-[16px] leading-snug mb-2" style={{ color: C.text1 }}>{sp.name}</div>
                    <p className="text-[13px] leading-relaxed mb-3" style={{ color: C.text2 }}>{sp.desc}…</p>
                    <div className="flex flex-wrap gap-1.5">
                      {sp.badges.map((b, j) => (
                        <span key={j} className="text-[11px] px-2.5 py-0.5 rounded-full" style={{ background: 'rgba(43,24,10,0.04)', color: C.dim }}>
                          {b.text}
                        </span>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </Reveal>
        )}

        {/* ══════ BOTTOM CTA ══════ */}
        <Reveal delay={600}>
          <div
            className="rounded-[16px] px-6 py-8 md:px-8 text-center"
            style={{ background: '#f1e7dc', border: `1px solid rgba(43,24,10,0.06)` }}
          >
            <h2 className="font-serif font-semibold text-[20px] md:text-[22px] mb-2" style={{ color: C.text1 }}>
              Готовы начать?
            </h2>
            <p className="text-[15px] mb-6 max-w-md mx-auto" style={{ color: C.text2 }}>
              Оставьте заявку — наш менеджер поможет с оформлением и подберёт оптимальные условия
            </p>
            <div className="flex gap-3 justify-center flex-wrap">
              <button
                className="inline-flex items-center gap-2 px-6 py-3 rounded-[13px] text-[15px] font-medium text-white transition-all duration-300 hover:brightness-[0.92]"
                style={{ backgroundColor: '#3f2407' }}
                onClick={() => setShowConsultation(true)}
              >
                <Send size={16} />
                Получить консультацию
              </button>
              <button
                className="inline-flex items-center gap-2 px-6 py-3 rounded-[13px] text-[15px] font-medium transition-all duration-300 hover:brightness-[0.92]"
                style={{ background: 'rgba(43,24,10,0.06)', color: C.text1 }}
                onClick={goToBuilder}
              >
                Собрать проект
              </button>
            </div>
          </div>
        </Reveal>

        {/* ══════ SHARE ROW ══════ */}
        <Reveal delay={650}>
          <div className="flex gap-2 flex-wrap mt-6 justify-center">
            <button className="text-[12px] px-3.5 py-1.5 rounded-full cursor-pointer flex items-center gap-1.5 transition-all duration-200 hover:opacity-70" style={{ background: 'rgba(43,24,10,0.04)', color: C.dim }}>
              <Share2 className="w-3.5 h-3.5" /> Поделиться
            </button>
            <button className="text-[12px] px-3.5 py-1.5 rounded-full cursor-pointer flex items-center gap-1.5 transition-all duration-200 hover:opacity-70" style={{ background: 'rgba(43,24,10,0.04)', color: C.dim }}>
              <FileDown className="w-3.5 h-3.5" /> Скачать PDF
            </button>
            <button className="text-[12px] px-3.5 py-1.5 rounded-full cursor-pointer flex items-center gap-1.5 transition-all duration-200 hover:opacity-70" style={{ background: 'rgba(43,24,10,0.04)', color: C.dim }} onClick={() => navigate('/finance/programs')}>
              <ArrowLeftRight className="w-3.5 h-3.5" /> Сравнить
            </button>
          </div>
        </Reveal>

        {/* ══════ CONSULTATION MODAL ══════ */}
        {showConsultation && (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4" style={{ background: 'rgba(0,0,0,0.5)' }}>
            <div className="rounded-[16px] p-6 md:p-8 max-w-md w-full space-y-5" style={{ background: C.pageBg, border: `1px solid ${C.blockBorder}` }}>
              <div>
                <h3 className="font-serif font-semibold text-[20px]" style={{ color: C.text1 }}>Заявка на консультацию</h3>
                <p className="text-[13px] mt-1" style={{ color: C.dim }}>Программа: {getName(program, lang)}</p>
              </div>
              <div className="space-y-1.5">
                <Label className="text-sm" style={{ color: C.text2 }}>Имя</Label>
                <Input value={consultForm.name} onChange={e => setConsultForm(p => ({ ...p, name: e.target.value }))} placeholder="Ваше имя" />
              </div>
              <div className="space-y-1.5">
                <Label className="text-sm" style={{ color: C.text2 }}>Телефон</Label>
                <Input value={consultForm.phone} onChange={e => setConsultForm(p => ({ ...p, phone: e.target.value }))} placeholder="+7 7XX XXX XXXX" />
              </div>
              <div className="space-y-1.5">
                <Label className="text-sm" style={{ color: C.text2 }}>Сообщение (необязательно)</Label>
                <Textarea value={consultForm.message} onChange={e => setConsultForm(p => ({ ...p, message: e.target.value }))} placeholder="Опишите ваш вопрос" rows={3} />
              </div>
              <div className="flex gap-3 pt-1">
                <button
                  className="flex-1 inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[13px] text-[15px] font-medium text-white transition-all duration-300 hover:brightness-[0.92]"
                  style={{ backgroundColor: '#3f2407' }}
                  onClick={handleConsultSubmit}
                  disabled={submitting}
                >
                  {submitting ? <TuranLoader variant="spin" size={16} /> : <Send className="h-4 w-4" />}
                  Отправить
                </button>
                <button
                  className="px-5 py-3 rounded-[13px] text-[14px] transition-all duration-200 hover:opacity-70"
                  style={{ background: 'rgba(43,24,10,0.04)', color: C.text1 }}
                  onClick={() => setShowConsultation(false)}
                >
                  Отмена
                </button>
              </div>
            </div>
          </div>
        )}
      </main>

      {/* ══════ STICKY FOOTER ══════ */}
      <div className={`fixed bottom-0 left-0 right-0 z-40 border-t backdrop-blur-[16px] transition-transform duration-300 ${showSticky ? 'translate-y-0' : 'translate-y-full'}`}
        style={{ background: 'rgba(253,246,238,0.92)', borderColor: C.blockBorder }}>
        <div className="max-w-[1200px] mx-auto px-4 md:px-10 py-3">
          {/* Desktop: single row | Mobile: stacked */}
          <div className="hidden md:flex justify-between items-center gap-4">
            <div className="min-w-0">
              <div className="text-[14px] font-medium truncate" style={{ color: C.text1 }}>{getName(program, lang)}</div>
              <div className="text-[12px]" style={{ color: C.dim }}>{d.heroBadges.slice(0, 3).map(b => b.text).join(' · ')}</div>
            </div>
            <div className="flex gap-2 shrink-0">
              <button className="text-[13px] px-4 py-2 rounded-[13px] cursor-pointer transition-all duration-200 hover:opacity-80" style={{ background: '#f1e7dc', color: C.text1 }} onClick={goToBuilder}>
                Подобрать
              </button>
              <button className="text-[13px] font-medium px-5 py-2 rounded-[13px] cursor-pointer text-white border-none transition-all duration-300 hover:brightness-[0.92]" style={{ background: '#3f2407' }} onClick={() => setShowConsultation(true)}>
                Получить консультацию
              </button>
            </div>
          </div>
          {/* Mobile: buttons only, no text */}
          <div className="flex md:hidden gap-2">
            <button className="flex-1 text-[13px] py-2.5 rounded-[13px] cursor-pointer transition-all duration-200 hover:opacity-80" style={{ background: '#f1e7dc', color: C.text1 }} onClick={goToBuilder}>
              Подобрать
            </button>
            <button className="flex-[2] text-[13px] font-medium py-2.5 rounded-[13px] cursor-pointer text-white border-none transition-all duration-300 hover:brightness-[0.92]" style={{ background: '#3f2407' }} onClick={() => setShowConsultation(true)}>
              Получить консультацию
            </button>
          </div>
        </div>
      </div>

    </div>
  );
};

export default ProgramDetailPage;

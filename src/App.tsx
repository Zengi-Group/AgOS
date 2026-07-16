import { lazy, Suspense } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { HelmetProvider } from 'react-helmet-async'
import { Toaster } from '@/components/ui/sonner'
import { AuthProvider } from '@/contexts/AuthContext'
import { HostProvider } from '@/platform/host/HostContext'
import { RequireAuth } from '@/components/guards/RequireAuth'
import { PushDeepLinkBridge } from '@/components/PushDeepLinkBridge'
import { BootScreen } from '@/components/BootScreen'
import { ShellBackGuard } from '@/pages/cabinet/shell/backGuard'

import { RequireExpert } from '@/components/guards/RequireExpert'
import { PublicLanding } from '@/components/guards/PublicLanding'
import { Login } from '@/pages/auth/Login'
import { Welcome } from '@/pages/auth/Welcome'
import { AdminLogin } from '@/pages/auth/AdminLogin'
import { ForgotPin } from '@/pages/auth/ForgotPin'
import { Registration } from '@/pages/registration/Registration'
import { Membership } from '@/pages/membership/Membership'
import { useAuth } from '@/hooks/useAuth'

// ── Public site (migrated from turan-industry-catalyst) ──────────────────────
const BusinessCard = lazy(() => import('@/pages/public/BusinessCard'))
const NewsPage = lazy(() => import('@/pages/public/news/NewsPage'))
const ArticlePage = lazy(() => import('@/pages/public/news/ArticlePage'))
const ArticleDrawer = lazy(() => import('@/pages/public/news/components/ArticleDrawer'))
const StartupsListing = lazy(() => import('@/pages/public/startups/StartupsListing'))
const StartupDetail = lazy(() => import('@/pages/public/startups/StartupDetail'))
const FinanceLayout = lazy(() => import('@/layouts/public/FinanceLayout'))
const FinanceLanding = lazy(() => import('@/pages/public/finance/FinanceLanding'))
const ProjectBuilder = lazy(() => import('@/pages/public/finance/ProjectBuilder'))
const ProgramsPage = lazy(() => import('@/pages/public/finance/ProgramsPage'))
const ProgramDetailPage = lazy(() => import('@/pages/public/finance/ProgramDetailPage'))
const SubsidiesLanding = lazy(() => import('@/pages/public/subsidies/SubsidiesLanding'))
const SubsidiesCatalog = lazy(() => import('@/pages/public/subsidies/SubsidiesCatalog'))
const SubsidyDetail = lazy(() => import('@/pages/public/subsidies/SubsidyDetail'))
const PassportDetail = lazy(() => import('@/pages/public/subsidies/PassportDetail'))
const SubsidyMatch = lazy(() => import('@/pages/public/subsidies/SubsidyMatch'))
const GlossaryPage = lazy(() => import('@/pages/public/subsidies/GlossaryPage'))
const SubsidyComparison = lazy(() => import('@/pages/public/subsidies/SubsidyComparison'))
const PublicMembershipPolicy = lazy(() => import('@/pages/public/MembershipPolicy'))

// ── Admin: news, startups, finance, subsidies, applications ──────────────────
const AdminNewsPage = lazy(() => import('@/pages/admin/news/AdminNewsPage'))
const CreateArticlePage = lazy(() => import('@/pages/admin/news/CreateArticlePage'))
const CreateMediaPage = lazy(() => import('@/pages/admin/news/CreateMediaPage'))
const EditNewsPage = lazy(() => import('@/pages/admin/news/EditNewsPage'))
const BackfillCoversPage = lazy(() => import('@/pages/admin/news/BackfillCovers'))
const BannersAdmin = lazy(() => import('@/pages/admin/content/BannersAdmin'))
const AdminStartupList = lazy(() => import('@/pages/admin/startups/StartupList'))
const AdminStartupDetail = lazy(() => import('@/pages/admin/startups/StartupDetail'))
const AdminProgramsPage = lazy(() => import('@/pages/admin/finance/AdminProgramsPage'))
const AdminProgramDepsPage = lazy(() => import('@/pages/admin/finance/AdminProgramDepsPage'))
const AdminFinanceRequestsPage = lazy(() => import('@/pages/admin/finance/AdminFinanceRequestsPage'))
const AdminSubsidiesPage = lazy(() => import('@/pages/admin/subsidies/AdminSubsidiesPage'))
const AdminPassportsPage = lazy(() => import('@/pages/admin/subsidies/AdminPassportsPage'))
const ApplicationsHub = lazy(() => import('@/pages/admin/applications/ApplicationsHub').then(m => ({ default: m.ApplicationsHub })))
const MembershipLevelTab = lazy(() => import('@/pages/admin/applications/MembershipLevelTab').then(m => ({ default: m.MembershipLevelTab })))
const EducationTab = lazy(() => import('@/pages/admin/applications/EducationTab').then(m => ({ default: m.EducationTab })))
// ── Legacy web-cabinet + admin/expert/consulting console — ВСЕ lazy (P-1, ARS-217) ──
// Раньше эти ~65 компонентов были eager static-import → падали в entry-чанк и грузились
// на первом кадре ФЕРМЕРА (гейт `!IS_NATIVE` — рантайм, код не вырезал). recharts (тяжёлый)
// протекал через eager consulting-табы. Перевод в lazy() выносит их из entry: фермер/нативка
// больше не качают код админки на старте; чанки грузятся только при заходе на web-роут.
// AppLayout — lazy: обёртка legacy+admin subtree, один Suspense на её element покрывает всё.
const AppLayout = lazy(() => import('@/components/layout/AppLayout').then(m => ({ default: m.AppLayout })))
const FarmProfile = lazy(() => import('@/pages/cabinet/FarmProfile').then(m => ({ default: m.FarmProfile })))
const ReportSick = lazy(() => import('@/pages/cabinet/vet/ReportSick').then(m => ({ default: m.ReportSick })))
const VetCaseList = lazy(() => import('@/pages/cabinet/vet/VetCaseList').then(m => ({ default: m.VetCaseList })))
const VetCaseDetail = lazy(() => import('@/pages/cabinet/vet/VetCaseDetail').then(m => ({ default: m.VetCaseDetail })))
const CabinetDashboard = lazy(() => import('@/pages/cabinet/CabinetDashboard').then(m => ({ default: m.CabinetDashboard })))
// New mobile shells (farmer + MPK) — own full-screen chrome, mounted OUTSIDE AppLayout.
// New = primary /cabinet; legacy web cabinet → /cabinet-legacy (CEO decision 2026-06-23).
// CabinetApp — lazy (S2, ревью PR #27): он тянет Ionic core.css с НЕслойным body-правилом
// и v5-остров — им нечего делать в main-чанке публичного сайта/админки (3G-бюджет Dok6);
// плюс каскад body перестаёт зависеть от порядка импортов в main.tsx.
const CabinetApp = lazy(() => import('@/pages/cabinet/shell/CabinetApp').then(m => ({ default: m.CabinetApp })))
// MpkApp — lazy (P-1): тоже нативная оболочка (Ionic-остров), не нужна в entry.
const MpkApp = lazy(() => import('@/pages/cabinet/shell/mpk/MpkApp').then(m => ({ default: m.MpkApp })))
const HerdOverview = lazy(() => import('@/pages/cabinet/herd/HerdOverview').then(m => ({ default: m.HerdOverview })))
const HerdGroupForm = lazy(() => import('@/pages/cabinet/herd/HerdGroupForm').then(m => ({ default: m.HerdGroupForm })))
const FeedInventory = lazy(() => import('@/pages/cabinet/feed/FeedInventory').then(m => ({ default: m.FeedInventory })))
const FeedItemForm = lazy(() => import('@/pages/cabinet/feed/FeedItemForm').then(m => ({ default: m.FeedItemForm })))
const RationPage = lazy(() => import('@/pages/cabinet/ration/RationPage').then(m => ({ default: m.RationPage })))
const RationCalculator = lazy(() => import('@/pages/cabinet/ration/tabs/Calculator').then(m => ({ default: m.Calculator })))
const GroupRations = lazy(() => import('@/pages/cabinet/ration/tabs/GroupRations').then(m => ({ default: m.GroupRations })))
const RationSummary = lazy(() => import('@/pages/cabinet/ration/tabs/Summary').then(m => ({ default: m.Summary })))
const RationBudget = lazy(() => import('@/pages/cabinet/ration/tabs/Budget').then(m => ({ default: m.Budget })))
const ProductionPlan = lazy(() => import('@/pages/cabinet/plan/ProductionPlan').then(m => ({ default: m.ProductionPlan })))
const TaskList = lazy(() => import('@/pages/cabinet/plan/TaskList').then(m => ({ default: m.TaskList })))
const Timeline = lazy(() => import('@/pages/cabinet/plan/Timeline').then(m => ({ default: m.Timeline })))
const CascadePreview = lazy(() => import('@/pages/cabinet/plan/CascadePreview').then(m => ({ default: m.CascadePreview })))
const KpiDashboard = lazy(() => import('@/pages/cabinet/plan/KpiDashboard').then(m => ({ default: m.KpiDashboard })))
const MarketDashboard = lazy(() => import('@/pages/cabinet/market/MarketDashboard').then(m => ({ default: m.MarketDashboard })))
const CreateBatch = lazy(() => import('@/pages/cabinet/market/CreateBatch').then(m => ({ default: m.CreateBatch })))
const BatchDetail = lazy(() => import('@/pages/cabinet/market/BatchDetail').then(m => ({ default: m.BatchDetail })))
const PriceInfo = lazy(() => import('@/pages/cabinet/market/PriceInfo').then(m => ({ default: m.PriceInfo })))
const AdminDashboard = lazy(() => import('@/pages/admin/AdminDashboard').then(m => ({ default: m.AdminDashboard })))
const MembershipDecision = lazy(() => import('@/pages/admin/MembershipDecision').then(m => ({ default: m.MembershipDecision })))
const VetCaseQueue = lazy(() => import('@/pages/admin/expert/VetCaseQueue').then(m => ({ default: m.VetCaseQueue })))
const CaseConsultation = lazy(() => import('@/pages/admin/expert/CaseConsultation').then(m => ({ default: m.CaseConsultation })))
const VaccinationPlans = lazy(() => import('@/pages/admin/expert/VaccinationPlans').then(m => ({ default: m.VaccinationPlans })))
const RecordVaccination = lazy(() => import('@/pages/admin/expert/RecordVaccination').then(m => ({ default: m.RecordVaccination })))
const EpidemicSignals = lazy(() => import('@/pages/admin/expert/EpidemicSignals').then(m => ({ default: m.EpidemicSignals })))
const ExpertKpi = lazy(() => import('@/pages/admin/expert/ExpertKpi').then(m => ({ default: m.ExpertKpi })))
const KnowledgeBase = lazy(() => import('@/pages/admin/knowledge/KnowledgeBase').then(m => ({ default: m.KnowledgeBase })))
const Restrictions = lazy(() => import('@/pages/admin/restrictions/Restrictions').then(m => ({ default: m.Restrictions })))
const AuditLog = lazy(() => import('@/pages/admin/audit/AuditLog').then(m => ({ default: m.AuditLog })))
const PoolQueue = lazy(() => import('@/pages/admin/pools/PoolQueue').then(m => ({ default: m.PoolQueue })))
const PoolDetail = lazy(() => import('@/pages/admin/pools/PoolDetail').then(m => ({ default: m.PoolDetail })))
const MarketplaceAdmin = lazy(() => import('@/pages/admin/marketplace/MarketplaceAdmin').then(m => ({ default: m.MarketplaceAdmin })))
const PriceGridManagement = lazy(() => import('@/pages/admin/pricing/PriceGridManagement').then(m => ({ default: m.PriceGridManagement })))
const UserManagement = lazy(() => import('@/pages/admin/users/UserManagement').then(m => ({ default: m.UserManagement })))
const RoleAssignment = lazy(() => import('@/pages/admin/roles/RoleAssignment').then(m => ({ default: m.RoleAssignment })))
const OrgManagement = lazy(() => import('@/pages/admin/orgs/OrgManagement').then(m => ({ default: m.OrgManagement })))
const RegionDirectory = lazy(() => import('@/pages/admin/regions/RegionDirectory').then(m => ({ default: m.RegionDirectory })))
const SystemSettings = lazy(() => import('@/pages/admin/settings/SystemSettings').then(m => ({ default: m.SystemSettings })))
const FeedReferenceAdmin = lazy(() => import('@/pages/admin/feeds/FeedReferenceAdmin').then(m => ({ default: m.FeedReferenceAdmin })))
const FeedCatalogTab = lazy(() => import('@/pages/admin/feeds/FeedReferenceAdmin').then(m => ({ default: m.CatalogTab })))
const FeedPricesTab = lazy(() => import('@/pages/admin/feeds/FeedReferenceAdmin').then(m => ({ default: m.PricesTab })))
const FeedNormsTab = lazy(() => import('@/pages/admin/feeds/FeedReferenceAdmin').then(m => ({ default: m.NormsTab })))
const CapexReferenceAdmin = lazy(() => import('@/pages/admin/capex/CapexReferenceAdmin').then(m => ({ default: m.CapexReferenceAdmin })))
const CapexMaterialsTab = lazy(() => import('@/pages/admin/capex/CapexReferenceAdmin').then(m => ({ default: m.CapexMaterialsTab })))
const CapexNormsTab = lazy(() => import('@/pages/admin/capex/CapexReferenceAdmin').then(m => ({ default: m.CapexNormsTab })))
const CapexSurchargesTab = lazy(() => import('@/pages/admin/capex/CapexReferenceAdmin').then(m => ({ default: m.CapexSurchargesTab })))
const LivestockPricesAdmin = lazy(() => import('@/pages/admin/livestock-prices/LivestockPricesAdmin').then(m => ({ default: m.LivestockPricesAdmin })))
const BillingPlansAdmin = lazy(() => import('@/pages/admin/billing/BillingPlansAdmin').then(m => ({ default: m.BillingPlansAdmin })))
const LivestockCategoriesLayout = lazy(() => import('@/pages/admin/livestock-categories/LivestockCategoriesLayout').then(m => ({ default: m.LivestockCategoriesLayout })))
const LivestockCategoriesTab = lazy(() => import('@/pages/admin/livestock-categories/LivestockCategoriesLayout').then(m => ({ default: m.CategoriesTab })))
const LivestockRulesTab = lazy(() => import('@/pages/admin/livestock-categories/LivestockCategoriesLayout').then(m => ({ default: m.RulesTab })))
const GradeFormulaAdmin = lazy(() => import('@/pages/admin/grade-formula/GradeFormulaAdmin').then(m => ({ default: m.GradeFormulaAdmin })))
const DirectoriesHub = lazy(() => import('@/pages/admin/directories/DirectoriesHub').then(m => ({ default: m.DirectoriesHub })))
const NormsReferenceAdmin = lazy(() => import('@/pages/admin/directories/norms/NormsReferenceAdmin').then(m => ({ default: m.NormsReferenceAdmin })))
const FacilityNormsTab = lazy(() => import('@/pages/admin/directories/norms/NormsReferenceAdmin').then(m => ({ default: m.FacilityNormsTab })))
const PaddockNormsTab = lazy(() => import('@/pages/admin/directories/norms/NormsReferenceAdmin').then(m => ({ default: m.PaddockNormsTab })))
const CalvingScenariosTab = lazy(() => import('@/pages/admin/directories/norms/NormsReferenceAdmin').then(m => ({ default: m.CalvingScenariosTab })))
const RegionalPastureTab = lazy(() => import('@/pages/admin/directories/norms/NormsReferenceAdmin').then(m => ({ default: m.RegionalPastureTab })))
const CapexCoefficientsTab = lazy(() => import('@/pages/admin/directories/norms/NormsReferenceAdmin').then(m => ({ default: m.CapexCoefficientsTab })))
const ConsultingDashboard = lazy(() => import('@/pages/admin/consulting/ConsultingDashboard').then(m => ({ default: m.ConsultingDashboard })))
const ProjectPage = lazy(() => import('@/pages/admin/consulting/ProjectPage').then(m => ({ default: m.ProjectPage })))
const ProjectWizard = lazy(() => import('@/pages/admin/consulting/ProjectWizard').then(m => ({ default: m.ProjectWizard })))
const SummaryTab = lazy(() => import('@/pages/admin/consulting/tabs/SummaryTab').then(m => ({ default: m.SummaryTab })))
const HerdTab = lazy(() => import('@/pages/admin/consulting/tabs/HerdTab').then(m => ({ default: m.HerdTab })))
const PnlTab = lazy(() => import('@/pages/admin/consulting/tabs/PnlTab').then(m => ({ default: m.PnlTab })))
const CashFlowTab = lazy(() => import('@/pages/admin/consulting/tabs/CashFlowTab').then(m => ({ default: m.CashFlowTab })))
const CapexTab = lazy(() => import('@/pages/admin/consulting/tabs/CapexTab').then(m => ({ default: m.CapexTab })))
const TechCardTab = lazy(() => import('@/pages/admin/consulting/tabs/TechCardTab').then(m => ({ default: m.TechCardTab })))
const RationTab = lazy(() => import('@/pages/admin/consulting/tabs/RationTab').then(m => ({ default: m.RationTab })))
const StaffTab = lazy(() => import('@/pages/admin/consulting/tabs/StaffTab').then(m => ({ default: m.StaffTab })))
import NotFound from '@/pages/public/NotFound'
import '@/i18n'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 2,
      staleTime: 30_000,
      refetchOnWindowFocus: false,
    },
  },
})

// App-target (EngSpec §8, ARS-150 / S4): нативный бандл (VITE_APP_TARGET=native) грузит
// ТОЛЬКО фермерскую оболочку /cabinet + МПК /mpk + auth — без публичного сайта, админки
// и экспертки (Apple 4.2 «minimum functionality»: приложение = функции фермера, не
// обёрнутый сайт). Гейт аддитивный — web-таргет монтирует всё как раньше.
const IS_NATIVE = import.meta.env.VITE_APP_TARGET === 'native'

// Native cold-start (ARS farmer-redesign): неавторизованных встречает тёмный
// Welcome (вход мобильного приложения); авторизованных уводим в кабинет.
// Web-таргет корня по-прежнему показывает публичный лендинг (PublicLanding).
function NativeEntry() {
  const { session, loading } = useAuth()
  // P-2 (ARS-218): пока резолвится сессия — брендовый boot вместо белого `null`.
  if (loading) return <BootScreen />
  return session ? <Navigate to="/cabinet" replace /> : <Welcome />
}

function App() {
  return (
    <HelmetProvider>
    <QueryClientProvider client={queryClient}>
      <HostProvider>
      <AuthProvider>
        <BrowserRouter>
          <PushDeepLinkBridge />
          {/* Граница истории оболочек: системный back/edge-swipe не выкидывает
              авторизованного из /cabinet|/mpk на auth-экран (см. backGuard.ts). */}
          <ShellBackGuard />
          <Routes>
            {/* Native: корень встречает неавторизованных тёмным Welcome, авторизованных — кабинетом. */}
            <Route path="/" element={IS_NATIVE ? <NativeEntry /> : <PublicLanding />} />
            <Route path="/welcome" element={<Welcome />} />
            <Route path="/login" element={<Login />} />
            <Route path="/forgot-pin" element={<ForgotPin />} />
            <Route path="/register" element={<Registration />} />
            <Route path="/membership" element={<Membership />} />

            {/* ── Публичный сайт + админ-логин: только web-таргет (§8) ─── */}
            {!IS_NATIVE && (
              <>
            <Route path="/admin/login" element={<AdminLogin />} />
            <Route path="/membership-policy" element={<Suspense fallback={null}><PublicMembershipPolicy /></Suspense>} />

            {/* ── Public site (migrated from turan-industry-catalyst) ─── */}
            {/* Legacy registration paths redirect to canonical /register (ADR-AUTH-CONSOLIDATE-01) */}
            <Route path="/join" element={<Navigate to="/register" replace />} />
            <Route path="/registration" element={<Navigate to="/register" replace />} />
            <Route path="/card" element={<Suspense fallback={null}><BusinessCard /></Suspense>} />
            <Route path="/news" element={<Suspense fallback={null}><NewsPage /></Suspense>}>
              <Route path=":slug" element={<Suspense fallback={null}><ArticleDrawer /></Suspense>} />
            </Route>
            <Route path="/article/:slug" element={<Suspense fallback={null}><ArticlePage /></Suspense>} />
            <Route path="/startups" element={<Suspense fallback={null}><StartupsListing /></Suspense>} />
            <Route path="/startups/:slug" element={<Suspense fallback={null}><StartupDetail /></Suspense>} />
            <Route element={<Suspense fallback={null}><FinanceLayout /></Suspense>}>
              <Route path="/finance" element={<Suspense fallback={null}><FinanceLanding /></Suspense>} />
              <Route path="/finance/build" element={<Suspense fallback={null}><ProjectBuilder /></Suspense>} />
              <Route path="/finance/programs" element={<Suspense fallback={null}><ProgramsPage /></Suspense>} />
              <Route path="/finance/programs/:id" element={<Suspense fallback={null}><ProgramDetailPage /></Suspense>} />
              <Route path="/subsidies" element={<Suspense fallback={null}><SubsidiesLanding /></Suspense>} />
              <Route path="/subsidies/catalog" element={<Suspense fallback={null}><SubsidiesCatalog /></Suspense>} />
              <Route path="/subsidies/match" element={<Suspense fallback={null}><SubsidyMatch /></Suspense>} />
              <Route path="/subsidies/passports" element={<Suspense fallback={null}><PassportDetail /></Suspense>} />
              <Route path="/subsidies/passports/:id" element={<Suspense fallback={null}><PassportDetail /></Suspense>} />
              <Route path="/subsidies/glossary" element={<Suspense fallback={null}><GlossaryPage /></Suspense>} />
              <Route path="/subsidies/compare" element={<Suspense fallback={null}><SubsidyComparison /></Suspense>} />
              <Route path="/subsidies/:id" element={<Suspense fallback={null}><SubsidyDetail /></Suspense>} />
            </Route>
              </>
            )}

            <Route element={<RequireAuth />}>
              {/* New mobile shells — full-screen, own chrome, NOT wrapped in AppLayout.
                  Primary /cabinet (farmer) + /mpk (МПК); legacy web cabinet → /cabinet-legacy. */}
              <Route path="/cabinet/*" element={<Suspense fallback={<BootScreen />}><CabinetApp /></Suspense>} />
              <Route path="/mpk/*" element={<Suspense fallback={<BootScreen />}><MpkApp /></Suspense>} />
              {/* Легаси web-кабинет + админ/эксперт-консоль: только web-таргет (§8). */}
              {!IS_NATIVE && (
              <Route element={<Suspense fallback={<BootScreen />}><AppLayout /></Suspense>}>
                <Route path="/cabinet-legacy">
                  <Route index element={<CabinetDashboard />} />
                  <Route path="farm" element={<FarmProfile />} />
                  <Route path="vet" element={<VetCaseList />} />
                  <Route path="vet/new" element={<ReportSick />} />
                  <Route path="vet/:caseId" element={<VetCaseDetail />} />
                  <Route path="herd" element={<HerdOverview />} />
                  <Route path="herd/add" element={<HerdGroupForm />} />
                  <Route path="herd/:groupId" element={<HerdGroupForm />} />
                  <Route path="feed" element={<FeedInventory />} />
                  <Route path="feed/add" element={<FeedItemForm />} />
                  <Route path="feed/:inventoryId" element={<FeedItemForm />} />
                  <Route path="ration" element={<RationPage />}>
                    <Route path="calculator" element={<RationCalculator />} />
                    <Route path="groups" element={<GroupRations />} />
                    <Route path="summary" element={<RationSummary />} />
                    <Route path="budget" element={<RationBudget />} />
                  </Route>
                  <Route path="plan" element={<ProductionPlan />} />
                  <Route path="plan/tasks" element={<TaskList />} />
                  <Route path="plan/timeline" element={<Timeline />} />
                  <Route path="plan/cascade/:phaseId" element={<CascadePreview />} />
                  <Route path="plan/kpi" element={<KpiDashboard />} />
                  <Route path="market" element={<MarketDashboard />} />
                  <Route path="market/new" element={<CreateBatch />} />
                  <Route path="market/batch/:batchId" element={<BatchDetail />} />
                  <Route path="market/prices" element={<PriceInfo />} />
                </Route>

                {/* All admin/expert routes: fn_is_expert() OR fn_is_admin() */}
                <Route element={<RequireExpert />}>
                  <Route path="/admin">
                    <Route index element={<AdminDashboard />} />
                    <Route path="expert/queue" element={<VetCaseQueue />} />
                    <Route path="expert/case/:caseId" element={<CaseConsultation />} />
                    <Route path="expert/vaccination" element={<VaccinationPlans />} />
                    <Route path="expert/vaccination/:planId/record" element={<RecordVaccination />} />
                    <Route path="expert/epidemic" element={<EpidemicSignals />} />
                    <Route path="expert/kpi" element={<ExpertKpi />} />
                    {/* legacy redirects — keep additive */}
                    <Route path="membership" element={<Navigate to="/admin/applications/level" replace />} />
                    <Route path="membership/:applicationId" element={<MembershipDecision />} />
                    <Route path="knowledge" element={<KnowledgeBase />} />
                    <Route path="restrictions" element={<Restrictions />} />
                    <Route path="audit" element={<AuditLog />} />
                    <Route path="marketplace" element={<MarketplaceAdmin />} />
                    <Route path="pools" element={<PoolQueue />} />
                    <Route path="pools/:poolId" element={<PoolDetail />} />
                    <Route path="pricing" element={<PriceGridManagement />} />
                    <Route path="users" element={<UserManagement />} />
                    <Route path="roles" element={<RoleAssignment />} />
                    <Route path="orgs" element={<OrgManagement />} />
                    <Route path="regions" element={<Navigate to="/admin/directories/regions" replace />} />
                    <Route path="settings" element={<SystemSettings />} />
                    {/* Legacy redirects → /admin/directories/* (routes kept, sidebar removed per HS-5) */}
                    <Route path="feeds" element={<Navigate to="/admin/directories/feeds/catalog" replace />} />
                    <Route path="feeds/*" element={<Navigate to="/admin/directories/feeds/catalog" replace />} />
                    <Route path="capex" element={<Navigate to="/admin/directories/capex/materials" replace />} />
                    <Route path="capex/*" element={<Navigate to="/admin/directories/capex/materials" replace />} />
                    <Route path="livestock-prices" element={<Navigate to="/admin/directories/livestock-prices" replace />} />
                    {/* ── Справочники hub ── */}
                    <Route path="directories" element={<DirectoriesHub />} />
                    <Route path="directories/feeds" element={<FeedReferenceAdmin />}>
                      <Route path="catalog" element={<FeedCatalogTab />} />
                      <Route path="prices" element={<FeedPricesTab />} />
                      <Route path="norms" element={<FeedNormsTab />} />
                    </Route>
                    <Route path="directories/capex" element={<CapexReferenceAdmin />}>
                      <Route path="materials" element={<CapexMaterialsTab />} />
                      <Route path="norms" element={<CapexNormsTab />} />
                      <Route path="surcharges" element={<CapexSurchargesTab />} />
                    </Route>
                    <Route path="directories/livestock-prices" element={<LivestockPricesAdmin />} />
                    {/* A-CAT — Категории скота + формула классификации */}
                    <Route path="livestock-categories" element={<LivestockCategoriesLayout />}>
                      <Route index element={<Navigate to="/admin/livestock-categories/categories" replace />} />
                      <Route path="categories" element={<LivestockCategoriesTab />} />
                      <Route path="rules" element={<LivestockRulesTab />} />
                    </Route>
                    {/* A-GRADE — Формула сорта МПК (упитанность → сорт + защитная цена) */}
                    <Route path="grade-formula" element={<GradeFormulaAdmin />} />
                    {/* ARS-207 — Конструктор планов членства (CRUD над membership_plan) */}
                    <Route path="billing/plans" element={<BillingPlansAdmin />} />
                    <Route path="directories/regions" element={<RegionDirectory />} />
                    <Route path="directories/norms" element={<NormsReferenceAdmin />}>
                      <Route path="facilities" element={<FacilityNormsTab />} />
                      <Route path="paddocks" element={<PaddockNormsTab />} />
                      <Route path="scenarios" element={<CalvingScenariosTab />} />
                      <Route path="pasture" element={<RegionalPastureTab />} />
                      <Route path="coefficients" element={<CapexCoefficientsTab />} />
                    </Route>
                    <Route path="consulting" element={<ConsultingDashboard />} />
                    <Route path="consulting/:projectId" element={<ProjectPage />}>
                      <Route path="edit" element={<ProjectWizard />} />
                      <Route path="summary" element={<SummaryTab />} />
                      <Route path="techcard" element={<TechCardTab />} />
                      <Route path="herd" element={<HerdTab />} />
                      <Route path="pnl" element={<PnlTab />} />
                      <Route path="cashflow" element={<CashFlowTab />} />
                      <Route path="capex" element={<CapexTab />} />
                      <Route path="staff" element={<StaffTab />} />
                      <Route path="ration" element={<RationTab />} />
                    </Route>

                    {/* ── Applications hub ── */}
                    <Route path="applications" element={<Suspense fallback={null}><ApplicationsHub /></Suspense>}>
                      <Route index element={<Navigate to="level" replace />} />
                      <Route path="level" element={<Suspense fallback={null}><MembershipLevelTab /></Suspense>} />
                      <Route path="level/:applicationId" element={<MembershipDecision />} />
                      <Route path="finance" element={<Suspense fallback={null}><AdminFinanceRequestsPage /></Suspense>} />
                      <Route path="education" element={<Suspense fallback={null}><EducationTab /></Suspense>} />
                    </Route>
                    <Route path="news" element={<Suspense fallback={null}><AdminNewsPage /></Suspense>} />
                    <Route path="news/create-article" element={<Suspense fallback={null}><CreateArticlePage /></Suspense>} />
                    <Route path="news/create-media" element={<Suspense fallback={null}><CreateMediaPage /></Suspense>} />
                    <Route path="news/:id/edit" element={<Suspense fallback={null}><EditNewsPage /></Suspense>} />
                    <Route path="news/backfill-covers" element={<Suspense fallback={null}><BackfillCoversPage /></Suspense>} />
                    <Route path="content/banners" element={<Suspense fallback={null}><BannersAdmin /></Suspense>} />
                    <Route path="startups" element={<Suspense fallback={null}><AdminStartupList /></Suspense>} />
                    <Route path="startups/:id" element={<Suspense fallback={null}><AdminStartupDetail /></Suspense>} />
                    <Route path="finance/programs" element={<Suspense fallback={null}><AdminProgramsPage /></Suspense>} />
                    <Route path="finance/deps" element={<Suspense fallback={null}><AdminProgramDepsPage /></Suspense>} />
                    <Route path="finance/requests" element={<Suspense fallback={null}><AdminFinanceRequestsPage /></Suspense>} />
                    <Route path="subsidies" element={<Suspense fallback={null}><AdminSubsidiesPage /></Suspense>} />
                    <Route path="subsidies/passports" element={<Suspense fallback={null}><AdminPassportsPage /></Suspense>} />
                  </Route>
                </Route>
              </Route>
              )}
            </Route>

            <Route path="*" element={<NotFound />} />
          </Routes>
        </BrowserRouter>
        <Toaster position="top-center" richColors />
      </AuthProvider>
      </HostProvider>
    </QueryClientProvider>
    </HelmetProvider>
  )
}

export default App

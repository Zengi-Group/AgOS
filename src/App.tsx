import { lazy, Suspense } from 'react'
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { HelmetProvider } from 'react-helmet-async'
import { Toaster } from '@/components/ui/sonner'
import { AuthProvider } from '@/contexts/AuthContext'
import { RequireAuth } from '@/components/guards/RequireAuth'

import { RequireExpert } from '@/components/guards/RequireExpert'
import { PublicLanding } from '@/components/guards/PublicLanding'
import { Login } from '@/pages/auth/Login'
import { AdminLogin } from '@/pages/auth/AdminLogin'
import { ForgotPin } from '@/pages/auth/ForgotPin'
import { Registration } from '@/pages/registration/Registration'

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
import { AppLayout } from '@/components/layout/AppLayout'
import { FarmProfile } from '@/pages/cabinet/FarmProfile'
import { ReportSick } from '@/pages/cabinet/vet/ReportSick'
import { VetCaseList } from '@/pages/cabinet/vet/VetCaseList'
import { VetCaseDetail } from '@/pages/cabinet/vet/VetCaseDetail'
import { CabinetDashboard } from '@/pages/cabinet/CabinetDashboard'
// New mobile shells (farmer + MPK) — own full-screen chrome, mounted OUTSIDE AppLayout.
// New = primary /cabinet; legacy web cabinet → /cabinet-legacy (CEO decision 2026-06-23).
import { CabinetApp } from '@/pages/cabinet/shell/CabinetApp'
import { MpkApp } from '@/pages/cabinet/shell/mpk/MpkApp'
import { HerdOverview } from '@/pages/cabinet/herd/HerdOverview'
import { HerdGroupForm } from '@/pages/cabinet/herd/HerdGroupForm'
import { FeedInventory } from '@/pages/cabinet/feed/FeedInventory'
import { FeedItemForm } from '@/pages/cabinet/feed/FeedItemForm'
import { RationPage } from '@/pages/cabinet/ration/RationPage'
import { Calculator as RationCalculator } from '@/pages/cabinet/ration/tabs/Calculator'
import { GroupRations } from '@/pages/cabinet/ration/tabs/GroupRations'
import { Summary as RationSummary } from '@/pages/cabinet/ration/tabs/Summary'
import { Budget as RationBudget } from '@/pages/cabinet/ration/tabs/Budget'
import { ProductionPlan } from '@/pages/cabinet/plan/ProductionPlan'
import { TaskList } from '@/pages/cabinet/plan/TaskList'
import { Timeline } from '@/pages/cabinet/plan/Timeline'
import { CascadePreview } from '@/pages/cabinet/plan/CascadePreview'
import { KpiDashboard } from '@/pages/cabinet/plan/KpiDashboard'
import { MarketDashboard } from '@/pages/cabinet/market/MarketDashboard'
import { CreateBatch } from '@/pages/cabinet/market/CreateBatch'
import { BatchDetail } from '@/pages/cabinet/market/BatchDetail'
import { PriceInfo } from '@/pages/cabinet/market/PriceInfo'
import { AdminDashboard } from '@/pages/admin/AdminDashboard'
import { MembershipDecision } from '@/pages/admin/MembershipDecision'
import { VetCaseQueue } from '@/pages/admin/expert/VetCaseQueue'
import { CaseConsultation } from '@/pages/admin/expert/CaseConsultation'
import { VaccinationPlans } from '@/pages/admin/expert/VaccinationPlans'
import { RecordVaccination } from '@/pages/admin/expert/RecordVaccination'
import { EpidemicSignals } from '@/pages/admin/expert/EpidemicSignals'
import { ExpertKpi } from '@/pages/admin/expert/ExpertKpi'
import { KnowledgeBase } from '@/pages/admin/knowledge/KnowledgeBase'
import { Restrictions } from '@/pages/admin/restrictions/Restrictions'
import { AuditLog } from '@/pages/admin/audit/AuditLog'
import { PoolQueue } from '@/pages/admin/pools/PoolQueue'
import { PoolDetail } from '@/pages/admin/pools/PoolDetail'
import { PriceGridManagement } from '@/pages/admin/pricing/PriceGridManagement'
import { UserManagement } from '@/pages/admin/users/UserManagement'
import { RoleAssignment } from '@/pages/admin/roles/RoleAssignment'
import { OrgManagement } from '@/pages/admin/orgs/OrgManagement'
import { RegionDirectory } from '@/pages/admin/regions/RegionDirectory'
import { SystemSettings } from '@/pages/admin/settings/SystemSettings'
import { FeedReferenceAdmin, CatalogTab as FeedCatalogTab, PricesTab as FeedPricesTab, NormsTab as FeedNormsTab } from '@/pages/admin/feeds/FeedReferenceAdmin'
import { CapexReferenceAdmin, CapexMaterialsTab, CapexNormsTab, CapexSurchargesTab } from '@/pages/admin/capex/CapexReferenceAdmin'
import { LivestockPricesAdmin } from '@/pages/admin/livestock-prices/LivestockPricesAdmin'
import { DirectoriesHub } from '@/pages/admin/directories/DirectoriesHub'
import { NormsReferenceAdmin, FacilityNormsTab, PaddockNormsTab, CalvingScenariosTab, RegionalPastureTab, CapexCoefficientsTab } from '@/pages/admin/directories/norms/NormsReferenceAdmin'
import { ConsultingDashboard } from '@/pages/admin/consulting/ConsultingDashboard'
import { ProjectPage } from '@/pages/admin/consulting/ProjectPage'
import { ProjectWizard } from '@/pages/admin/consulting/ProjectWizard'
import { SummaryTab } from '@/pages/admin/consulting/tabs/SummaryTab'
import { HerdTab } from '@/pages/admin/consulting/tabs/HerdTab'
import { PnlTab } from '@/pages/admin/consulting/tabs/PnlTab'
import { CashFlowTab } from '@/pages/admin/consulting/tabs/CashFlowTab'
import { CapexTab } from '@/pages/admin/consulting/tabs/CapexTab'
import { TechCardTab } from '@/pages/admin/consulting/tabs/TechCardTab'
import { RationTab } from '@/pages/admin/consulting/tabs/RationTab'
import { StaffTab } from '@/pages/admin/consulting/tabs/StaffTab'
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

function App() {
  return (
    <HelmetProvider>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/" element={<PublicLanding />} />
            <Route path="/login" element={<Login />} />
            <Route path="/admin/login" element={<AdminLogin />} />
            <Route path="/forgot-pin" element={<ForgotPin />} />
            <Route path="/register" element={<Registration />} />
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

            <Route element={<RequireAuth />}>
              {/* New mobile shells — full-screen, own chrome, NOT wrapped in AppLayout.
                  Primary /cabinet (farmer) + /mpk (МПК); legacy web cabinet → /cabinet-legacy. */}
              <Route path="/cabinet/*" element={<CabinetApp />} />
              <Route path="/mpk/*" element={<MpkApp />} />
              <Route element={<AppLayout />}>
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
            </Route>

            <Route path="*" element={<NotFound />} />
          </Routes>
        </BrowserRouter>
        <Toaster position="top-center" richColors />
      </AuthProvider>
    </QueryClientProvider>
    </HelmetProvider>
  )
}

export default App

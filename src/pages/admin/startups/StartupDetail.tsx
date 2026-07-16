import { useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { ArrowLeft, ExternalLink, Mail, Phone, Globe, FileText, Video, Users } from 'lucide-react';
import { TuranLoader } from '@/components/TuranLoader';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import StartupStatusBadge from '@/components/admin/StartupStatusBadge';
import RejectDialog from '@/components/admin/RejectDialog';
import { useAdminStartup } from '@/hooks/admin/useAdminStartup';
import { useApproveStartup } from '@/hooks/admin/useApproveStartup';
import { useRejectStartup } from '@/hooks/admin/useRejectStartup';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel,
  AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';

// ─────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3
        className="text-xs uppercase tracking-wider mb-3"
        style={{ color: 'var(--fg3)', letterSpacing: '0.05em' }}
      >
        {title}
      </h3>
      <div className="grid grid-cols-2 gap-x-6 gap-y-4">
        {children}
      </div>
    </div>
  );
}

function Field({ label, value, colSpan2 }: { label: string; value: React.ReactNode; colSpan2?: boolean }) {
  return (
    <div className={colSpan2 ? 'col-span-2' : ''}>
      <p className="text-xs mb-0.5" style={{ color: 'var(--fg3)' }}>{label}</p>
      <p className="text-sm whitespace-pre-wrap" style={{ color: 'var(--fg)' }}>{value || '—'}</p>
    </div>
  );
}

function formatAmount(amount: number | null): string {
  if (!amount) return '—';
  return `$${amount.toLocaleString('en-US')}`;
}

// ─────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────

export default function AdminStartupDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { t } = useTranslation();

  const { data: startup, isLoading, error } = useAdminStartup(id);
  const approve = useApproveStartup();
  const reject = useRejectStartup();

  const [approveOpen, setApproveOpen] = useState(false);
  const [rejectOpen, setRejectOpen] = useState(false);

  const months = t('admin.months', { returnObjects: true }) as string[];

  function formatDateFull(iso: string): string {
    const d = new Date(iso);
    return `${d.getDate()} ${months[d.getMonth()]} ${d.getFullYear()}, ${d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}`;
  }

  const handleApprove = async () => {
    try {
      await approve.mutateAsync(id!);
      toast.success(t('admin.startupDetail.approvedToast'));
      navigate('/admin/startups');
    } catch (err: any) {
      toast.error(err.message || t('admin.startupDetail.approveError'));
    }
    setApproveOpen(false);
  };

  const handleReject = async (reason: string) => {
    try {
      await reject.mutateAsync({ id: id!, reason });
      toast.success(t('admin.startupDetail.rejectedToast'));
      navigate('/admin/startups');
    } catch (err: any) {
      toast.error(err.message || t('admin.startupDetail.rejectError'));
    }
    setRejectOpen(false);
  };

  // Loading
  if (isLoading) {
    return (
      <div className="min-h-screen" style={{ background: 'var(--bg)' }}>
        <div className="mx-auto max-w-2xl px-4 py-8 space-y-6">
          <Skeleton className="h-4 w-48" />
          <Skeleton className="h-8 w-64" />
          <Skeleton className="h-32 w-full" />
          <Skeleton className="h-32 w-full" />
        </div>
      </div>
    );
  }

  // Error
  if (error || !startup) {
    return (
      <div className="min-h-screen" style={{ background: 'var(--bg)' }}>
        <div className="mx-auto max-w-2xl px-4 py-8 text-center">
          <p className="text-sm mb-3" style={{ color: 'var(--red)' }}>{t('admin.startupDetail.notFound')}</p>
          <Button variant="outline" onClick={() => navigate('/admin/startups')}>
            {t('admin.startupDetail.backToList')}
          </Button>
        </div>
      </div>
    );
  }

  const isPending = startup.submission_status === 'pending_review';

  return (
    <div className="min-h-screen" style={{ background: 'var(--bg)' }}>
      <div className="mx-auto max-w-2xl px-4 sm:px-6 py-6 sm:py-8">

        {/* Navigation */}
        <div className="mb-6">
          <Link
            to="/admin/startups"
            className="inline-flex items-center gap-1.5 text-sm transition-colors"
            style={{ color: 'var(--fg3)' }}
          >
            <ArrowLeft className="w-4 h-4" />
            {t('admin.startupDetail.backToList')}
          </Link>
        </div>

        {/* Header */}
        <div
          className="rounded-xl border p-5 sm:p-6 mb-4"
          style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}
        >
          <div className="flex items-start justify-between mb-4">
            <StartupStatusBadge status={startup.submission_status} />
            <p className="text-xs" style={{ color: 'var(--fg3)' }}>
              {formatDateFull(startup.created_at)}
            </p>
          </div>

          <h1 className="text-xl sm:text-2xl font-semibold mb-1" style={{ color: 'var(--fg)' }}>
            {startup.title}
          </h1>
          {startup.tagline && (
            <p className="text-sm mb-3" style={{ color: 'var(--fg2)' }}>{startup.tagline}</p>
          )}

          <div className="flex flex-wrap items-center gap-3">
            {startup.contact_name && (
              <span className="text-sm" style={{ color: 'var(--fg)' }}>{startup.contact_name}</span>
            )}
            {startup.contact_email && (
              <a
                href={`mailto:${startup.contact_email}`}
                className="inline-flex items-center gap-1 text-sm"
                style={{ color: 'var(--fg)' }}
              >
                <Mail className="w-3.5 h-3.5" /> {startup.contact_email}
              </a>
            )}
            {startup.contact_phone && (
              <a
                href={`tel:${startup.contact_phone}`}
                className="inline-flex items-center gap-1 text-sm"
                style={{ color: 'var(--fg)' }}
              >
                <Phone className="w-3.5 h-3.5" /> {startup.contact_phone}
              </a>
            )}
          </div>
        </div>

        {/* About */}
        <div className="rounded-xl border p-5 sm:p-6 mb-4" style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}>
          <Section title={t('admin.startupDetail.about')}>
            <Field label={t('admin.startupDetail.category')} value={t(`constants.startupCategories.${startup.category}`)} />
            <Field label={t('admin.startupDetail.stage')} value={t(`constants.startupStages.${startup.stage}`)} />
            <Field label={t('admin.startupDetail.region')} value={startup.location_region ? t(`constants.regions.${startup.location_region}`, startup.location_region) : null} />
            <Field label={t('admin.startupDetail.yearFounded')} value={startup.year_founded} />
            <Field label={t('admin.startupDetail.problem')} value={startup.description_problem} colSpan2 />
            <Field label={t('admin.startupDetail.solution')} value={startup.description_solution} colSpan2 />
            <Field label={t('admin.startupDetail.targetMarket')} value={startup.target_market} colSpan2 />
            <Field label={t('admin.startupDetail.businessModel')} value={startup.business_model} colSpan2 />
          </Section>
        </div>

        {/* Investment */}
        <div className="rounded-xl border p-5 sm:p-6 mb-4" style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}>
          <Section title={t('admin.startupDetail.investment')}>
            <Field label={t('admin.startupDetail.fundingAsk')} value={formatAmount(startup.funding_ask)} />
            <Field label={t('admin.startupDetail.fundingRaised')} value={formatAmount(startup.funding_raised)} />
            <Field label={t('admin.startupDetail.fundingInstrument')} value={startup.funding_instrument} />
            <Field label={t('admin.startupDetail.fundingStatus')} value={t(`constants.fundingStatuses.${startup.funding_status}`)} />
          </Section>

          {/* Use of funds */}
          {startup.use_of_funds.length > 0 && (
            <div className="mt-4 pt-4" style={{ borderTop: '1px solid var(--bd-s)' }}>
              <p className="text-xs mb-2" style={{ color: 'var(--fg3)' }}>{t('admin.startupDetail.useOfFunds')}</p>
              <div className="space-y-2">
                {startup.use_of_funds.map(item => (
                  <div key={item.id} className="flex items-center justify-between text-sm">
                    <span style={{ color: 'var(--fg)' }}>{item.item}</span>
                    <span className="font-medium" style={{ color: 'var(--fg2)' }}>{item.percentage}%</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Team */}
        <div className="rounded-xl border p-5 sm:p-6 mb-4" style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}>
          <Section title={t('admin.startupDetail.team')}>
            <Field label={t('admin.startupDetail.teamSize')} value={startup.team_size} />
            <Field label={t('admin.startupDetail.yearFounded')} value={startup.year_founded} />
          </Section>

          {startup.team_members.length > 0 && (
            <div className="mt-4 pt-4" style={{ borderTop: '1px solid var(--bd-s)' }}>
              <p className="text-xs mb-3" style={{ color: 'var(--fg3)' }}>
                <Users className="w-3 h-3 inline mr-1" />
                {t('admin.startupDetail.teamMembers')}
              </p>
              <div className="space-y-3">
                {startup.team_members.map(member => (
                  <div key={member.id}>
                    <p className="text-sm font-medium" style={{ color: 'var(--fg)' }}>{member.name}</p>
                    {member.role && <p className="text-xs" style={{ color: 'var(--fg3)' }}>{member.role}</p>}
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Materials */}
        <div className="rounded-xl border p-5 sm:p-6 mb-4" style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}>
          <h3
            className="text-xs uppercase tracking-wider mb-3"
            style={{ color: 'var(--fg3)', letterSpacing: '0.05em' }}
          >
            {t('admin.startupDetail.materials')}
          </h3>
          <div className="flex flex-wrap gap-2">
            {startup.pitch_deck_url && (
              <a
                href={startup.pitch_deck_url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm border transition-colors hover:bg-[var(--bg-m)]"
                style={{ borderColor: 'var(--bd)', color: 'var(--fg)' }}
              >
                <FileText className="w-3.5 h-3.5" /> Pitch Deck <ExternalLink className="w-3 h-3" />
              </a>
            )}
            {startup.one_pager_url && (
              <a
                href={startup.one_pager_url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm border transition-colors hover:bg-[var(--bg-m)]"
                style={{ borderColor: 'var(--bd)', color: 'var(--fg)' }}
              >
                <FileText className="w-3.5 h-3.5" /> One Pager <ExternalLink className="w-3 h-3" />
              </a>
            )}
            {startup.video_url && (
              <a
                href={startup.video_url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm border transition-colors hover:bg-[var(--bg-m)]"
                style={{ borderColor: 'var(--bd)', color: 'var(--fg)' }}
              >
                <Video className="w-3.5 h-3.5" /> Video <ExternalLink className="w-3 h-3" />
              </a>
            )}
            {startup.website_url && (
              <a
                href={startup.website_url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm border transition-colors hover:bg-[var(--bg-m)]"
                style={{ borderColor: 'var(--bd)', color: 'var(--fg)' }}
              >
                <Globe className="w-3.5 h-3.5" /> Website <ExternalLink className="w-3 h-3" />
              </a>
            )}
            {!startup.pitch_deck_url && !startup.one_pager_url && !startup.video_url && !startup.website_url && (
              <p className="text-sm" style={{ color: 'var(--fg3)' }}>{t('admin.startupDetail.noMaterials')}</p>
            )}
          </div>
        </div>

        {/* Review info (if not pending) */}
        {!isPending && (
          <div className="rounded-xl border p-5 sm:p-6 mb-4" style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}>
            <Section title={t('admin.startupDetail.review')}>
              <Field
                label={t('admin.startupDetail.decision')}
                value={startup.submission_status === 'approved' ? t('admin.startupDetail.approvedStatus') : t('admin.startupDetail.rejectedStatus')}
              />
              <Field label={t('admin.startupDetail.published')} value={startup.is_published ? t('admin.startupDetail.yes') : t('admin.startupDetail.no')} />
              {startup.submission_status === 'rejected' && startup.rejection_reason && (
                <Field label={t('admin.startupDetail.rejectionReason')} value={startup.rejection_reason} colSpan2 />
              )}
            </Section>
          </div>
        )}

        {/* Actions (pending only) */}
        {isPending && (
          <div
            className="rounded-xl border p-4 sm:p-5 mt-4 flex gap-3"
            style={{ background: 'var(--bg-c)', borderColor: 'var(--bd-s)' }}
          >
            <Button
              className="flex-1 h-11 text-white font-medium"
              style={{ background: 'var(--cta)', color: 'var(--cta-fg)' }}
              onClick={() => setApproveOpen(true)}
              disabled={approve.isPending || reject.isPending}
            >
              {approve.isPending && <TuranLoader variant="spin" size={16} className="mr-2" />}
              {t('admin.startupDetail.approveBtn')}
            </Button>
            <Button
              variant="outline"
              className="flex-1 h-11 font-medium"
              style={{ color: 'var(--red)', borderColor: 'var(--bd)' }}
              onClick={() => setRejectOpen(true)}
              disabled={approve.isPending || reject.isPending}
            >
              {reject.isPending && <TuranLoader variant="spin" size={16} className="mr-2" />}
              {t('admin.startupDetail.rejectBtn')}
            </Button>
          </div>
        )}

        {/* Approve Dialog */}
        <AlertDialog open={approveOpen} onOpenChange={setApproveOpen}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>{t('admin.startupApproveDialog.title')}</AlertDialogTitle>
              <AlertDialogDescription>
                {t('admin.startupApproveDialog.description', { title: startup.title })}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={approve.isPending}>{t('admin.startupApproveDialog.cancel')}</AlertDialogCancel>
              <AlertDialogAction
                onClick={handleApprove}
                disabled={approve.isPending}
                style={{ background: 'var(--cta)', color: 'var(--cta-fg)' }}
              >
                {approve.isPending ? t('admin.startupApproveDialog.approving') : t('admin.startupApproveDialog.approve')}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>

        {/* Reject Dialog (reusing existing component) */}
        <RejectDialog
          open={rejectOpen}
          onOpenChange={setRejectOpen}
          isPending={reject.isPending}
          onConfirm={handleReject}
        />
      </div>
    </div>
  );
}

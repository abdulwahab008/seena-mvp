import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDatePk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { ApplicantBoard, ApplicantForm, OpeningForm } from './recruitment-forms';

export const dynamic = 'force-dynamic';

const RECRUITERS = ['super_admin', 'owner', 'principal', 'vice_principal', 'hr_manager'];

export default async function RecruitmentPage({ searchParams }: { searchParams: Promise<{ job?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !RECRUITERS.includes(actor.role)) notFound();
  const { job } = await searchParams;

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const { data: openings } = await supabase
    .from('job_opening')
    .select('id, title, positions, status, closes_on, job_application(stage)')
    .eq('campus_id', campus.id)
    .order('created_at', { ascending: false });
  const selected = (openings ?? []).find((o) => o.id === job) ?? (openings ?? [])[0];
  const { data: applicants } = selected
    ? await supabase
        .from('job_application')
        .select('id, candidate_name, phone, email, qualification, experience_yrs, source, stage, interview_at, job_application_event(to_stage, note, created_at)')
        .eq('job_opening_id', selected.id)
        .order('created_at')
    : { data: [] };

  return (
    <>
      <PageHeader title="Recruitment" description="Job openings and their applicants, from application to hire." />
      <div className="grid gap-6 lg:grid-cols-[18rem_1fr]">
        <div className="space-y-3">
          <nav className="space-y-1" aria-label="Openings">
            {(openings ?? []).map((o) => {
              const active = (o.job_application ?? []).filter((a) => !['hired', 'rejected', 'withdrawn'].includes(a.stage)).length;
              const hired = (o.job_application ?? []).filter((a) => a.stage === 'hired').length;
              return (
                <Link
                  key={o.id}
                  href={`/staff/recruitment?job=${o.id}`}
                  className={cn('block rounded-md border px-3 py-2 text-sm', o.id === selected?.id ? 'border-primary bg-primary/5' : 'hover:bg-muted')}
                >
                  <span className="font-medium">{o.title}</span>
                  <span className="block text-xs text-muted-foreground">
                    {o.status} · {active} in progress · {hired}/{o.positions} hired{o.closes_on ? ` · closes ${formatDatePk(o.closes_on)}` : ''}
                  </span>
                </Link>
              );
            })}
            {(openings ?? []).length === 0 && <p className="text-sm text-muted-foreground">No openings yet.</p>}
          </nav>
          <OpeningForm campusId={campus.id} />
        </div>
        {selected ? (
          <div className="space-y-4">
            <ApplicantBoard
              applicants={(applicants ?? []).map((a) => ({
                id: a.id,
                name: a.candidate_name,
                contact: [a.phone, a.email].filter(Boolean).join(' · '),
                profile: [a.qualification, a.experience_yrs != null ? `${a.experience_yrs} yrs` : null, a.source].filter(Boolean).join(' · '),
                stage: a.stage,
                interviewAt: a.interview_at,
                lastNote: [...(a.job_application_event ?? [])].sort((x, y) => y.created_at.localeCompare(x.created_at)).find((e) => e.note)?.note ?? null,
              }))}
            />
            {selected.status !== 'closed' && <ApplicantForm jobOpeningId={selected.id} />}
          </div>
        ) : (
          <EmptyState title="Post your first opening" description="Use the form on the left." />
        )}
      </div>
    </>
  );
}

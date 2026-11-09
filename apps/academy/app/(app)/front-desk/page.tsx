import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { cn } from '@/lib/utils';
import { PageHeader, Stat } from '@/components/ui/page-header';
import { todayPk } from '@/lib/dates';
import { EmptyState } from '@/components/ui/empty-state';
import { FRONT_DESK_KINDS, FRONT_DESK_ROLES, KIND_CONFIG, type FrontDeskKind } from './kinds';
import { EntryList } from './entry-list';
import { NewEntryForm } from './new-entry-form';
import { QuickSmsPanel } from './quick-sms-panel';

export const dynamic = 'force-dynamic';

export default async function FrontDeskPage({ searchParams }: { searchParams: Promise<{ kind?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !FRONT_DESK_ROLES.includes(actor.role)) notFound();
  const { kind: rawKind } = await searchParams;
  const kind: FrontDeskKind = (FRONT_DESK_KINDS as readonly string[]).includes(rawKind ?? '') ? (rawKind as FrontDeskKind) : 'visitor';

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
  const today = todayPk();
  const startOfToday = `${today}T00:00:00+05:00`;
  const [{ data: entries }, { data: open }, { data: sectionRows }, { data: todays }, { count: enquiriesToday }] = await Promise.all([
    supabase
      .from('front_desk_entry')
      .select('id, person_name, phone, purpose, host_name, reference, details, opened_at, follow_up_on, closed_at')
      .eq('campus_id', campus.id)
      .eq('kind', kind)
      .or(`closed_at.is.null,opened_at.gte.${since}`)
      .order('closed_at', { ascending: false, nullsFirst: true })
      .order('opened_at', { ascending: false })
      .limit(200),
    supabase.from('front_desk_entry').select('kind, follow_up_on').eq('campus_id', campus.id).is('closed_at', null),
    supabase.from('class_section').select('id, name, class_level:class_level_id(name_en, ordinal)').eq('campus_id', campus.id).eq('is_active', true),
    supabase.from('front_desk_entry').select('kind, follow_up_on').eq('campus_id', campus.id).or(`opened_at.gte.${startOfToday},follow_up_on.eq.${today}`),
    supabase.from('admission_enquiry').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).gte('created_at', startOfToday),
  ]);
  const sections = (sectionRows ?? [])
    .map((s) => ({ id: s.id, label: `${one(s.class_level)?.name_en ?? ''} ${s.name}`.trim(), sort: one(s.class_level)?.ordinal ?? 0 }))
    .sort((a, b) => a.sort - b.sort || a.label.localeCompare(b.label))
    .map(({ id, label }) => ({ id, label }));
  const openCount = (k: string) => (open ?? []).filter((o) => o.kind === k).length;
  const followUpsDue = (open ?? []).filter((o) => o.kind !== 'appointment' && o.follow_up_on && o.follow_up_on <= today).length;
  const todayCount = (k: FrontDeskKind) => (todays ?? []).filter((t) => t.kind === k && (k !== 'appointment' || t.follow_up_on === today)).length;

  return (
    <>
      <PageHeader title="Front desk" description={`Registers for ${campus.name}: who came in, who called, what arrived and who went out.`} />
      <section aria-label="Needs attention" className="mb-4 grid gap-3 sm:grid-cols-3 xl:grid-cols-5">
        <Stat label="Follow-ups due" value={followUpsDue} tone={followUpsDue > 0 ? 'warning' : 'default'} hint="Due today or overdue" />
        <Stat label="Parcels waiting" value={openCount('parcel')} hint="Not yet collected" />
        <Stat label="Open complaints" value={openCount('complaint')} tone={openCount('complaint') > 0 ? 'destructive' : 'default'} hint="Not yet resolved" />
        <Stat label="Call-backs" value={openCount('call')} hint="Open calls" />
        <Stat label="Lost items" value={openCount('lost_found')} hint="Unclaimed" />
      </section>
      <section aria-label="Today at the desk" className="mb-6 grid gap-3 sm:grid-cols-3 xl:grid-cols-5">
        <Stat label="Enquiries today" value={enquiriesToday ?? 0} />
        <Stat label="Visitors today" value={todayCount('visitor')} hint={`${openCount('visitor')} still inside`} />
        <Stat label="Appointments today" value={todayCount('appointment')} />
        <Stat label="Gate passes today" value={todayCount('gate_pass')} hint={`${openCount('gate_pass')} not yet back`} />
        <Stat label="Directory" value={openCount('contact')} hint="Saved contacts" />
      </section>
      <nav className="mb-4 flex flex-wrap gap-2" aria-label="Registers">
        {FRONT_DESK_KINDS.map((k) => (
          <Link
            key={k}
            href={`/front-desk?kind=${k}`}
            className={cn('rounded-full border px-3 py-1 text-sm', k === kind ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted')}
            aria-current={k === kind ? 'page' : undefined}
          >
            {KIND_CONFIG[k].tab}
            {openCount(k) > 0 ? ` (${openCount(k)})` : ''}
          </Link>
        ))}
      </nav>
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <EntryList kind={kind} entries={entries ?? []} />
        <div className="space-y-6">
          <NewEntryForm key={kind} kind={kind} campusId={campus.id} />
          <QuickSmsPanel campusId={campus.id} sections={sections} />
        </div>
      </div>
    </>
  );
}

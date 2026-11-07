import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { cn } from '@/lib/utils';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { FRONT_DESK_KINDS, FRONT_DESK_ROLES, KIND_CONFIG, type FrontDeskKind } from './kinds';
import { EntryList } from './entry-list';
import { NewEntryForm } from './new-entry-form';

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
  const [{ data: entries }, { data: open }] = await Promise.all([
    supabase
      .from('front_desk_entry')
      .select('id, person_name, phone, purpose, host_name, reference, details, opened_at, follow_up_on, closed_at')
      .eq('campus_id', campus.id)
      .eq('kind', kind)
      .or(`closed_at.is.null,opened_at.gte.${since}`)
      .order('closed_at', { ascending: false, nullsFirst: true })
      .order('opened_at', { ascending: false })
      .limit(200),
    supabase.from('front_desk_entry').select('kind').eq('campus_id', campus.id).is('closed_at', null),
  ]);
  const openCount = (k: string) => (open ?? []).filter((o) => o.kind === k).length;

  return (
    <>
      <PageHeader title="Front desk" description={`Registers for ${campus.name}: who came in, who called, what arrived and who went out.`} />
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
        <NewEntryForm key={kind} kind={kind} campusId={campus.id} />
      </div>
    </>
  );
}

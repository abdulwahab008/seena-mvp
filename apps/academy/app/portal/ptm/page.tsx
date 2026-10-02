import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t } from '@/lib/i18n/messages';
import { SlotBoard } from './slot-board';
import type { PtmSlot } from './actions';

type SearchParams = { child?: string; event?: string };

export default async function PortalPtmPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const lang = await getLang();
  const supabase = await supabaseServer();

  const [{ data: enrolments }, { data: events }] = await Promise.all([
    supabase.from('enrolment').select('student_id, student:student_id(name_en)').eq('status', 'active'),
    supabase.from('ptm_event').select('id, title, event_date, booking_opens_at, booking_cutoff_at').eq('status', 'open').gte('event_date', new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })).order('event_date'),
  ]);
  const children = (enrolments ?? []).map((e) => {
    const s = Array.isArray(e.student) ? e.student[0] : e.student;
    return { id: e.student_id, name: s?.name_en ?? '' };
  });
  const child = children.find((c) => c.id === sp.child) ?? children[0];
  const event = (events ?? []).find((e) => e.id === sp.event) ?? events?.[0];

  let slots: PtmSlot[] = [];
  const myBookings: Record<string, string> = {};
  if (child && event) {
    const [{ data: list }, { data: mine }] = await Promise.all([
      supabase.rpc('ptm_slot_list', { p_event_id: event.id, p_student_id: child.id }),
      supabase.from('ptm_booking').select('id, slot_id').eq('event_id', event.id).eq('student_id', child.id).eq('status', 'confirmed'),
    ]);
    slots = (list ?? []) as unknown as PtmSlot[];
    for (const b of mine ?? []) myBookings[b.slot_id] = b.id;
  }
  const cutoff = event ? new Date(event.booking_cutoff_at).toLocaleString('en-GB', { timeZone: 'Asia/Karachi', dateStyle: 'medium', timeStyle: 'short' }) : '';

  return (
    <div className="space-y-6">
      <h2 className="text-2xl font-semibold">{t(lang, 'ptm.title')}</h2>
      {children.length > 1 && (
        <div className="flex flex-wrap gap-2" data-testid="ptm-child-selector">
          {children.map((c) => (
            <Link key={c.id} href={`/portal/ptm?child=${c.id}`} className={`rounded-full border px-3 py-1 text-sm ${c.id === child?.id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}>
              {c.name}
            </Link>
          ))}
        </div>
      )}
      {!event || !child ? (
        <p className="text-sm text-muted-foreground">{t(lang, 'ptm.noEvents')}</p>
      ) : (
        <>
          <div>
            <p className="font-medium">
              {event.title} · {event.event_date}
            </p>
            <p className="text-sm text-muted-foreground" data-testid="ptm-cutoff">
              {t(lang, 'ptm.bookingCloses', { time: cutoff })}
            </p>
          </div>
          <SlotBoard key={`${child.id}-${event.id}`} studentId={child.id} initial={slots} myBookings={myBookings} lang={lang} />
        </>
      )}
    </div>
  );
}

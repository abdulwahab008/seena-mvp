import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EventForm, SlotsForm } from './ptm-forms';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const fmt = (iso: string) => new Date(iso).toLocaleString('en-GB', { timeZone: 'Asia/Karachi', dateStyle: 'medium', timeStyle: 'short' });

export default async function PtmPage() {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const [{ data: events }, { data: staff }] = await Promise.all([
    supabase.from('ptm_event').select('id, title, event_date, starts_at, booking_opens_at, booking_cutoff_at, slot_minutes').order('event_date', { ascending: false }).limit(10),
    supabase.from('app_user').select('user_id, full_name, app_role').in('app_role', ['class_teacher', 'subject_teacher', 'head_of_department']).order('full_name'),
  ]);
  const teachers = (staff ?? []).map((s) => ({ id: s.user_id, name: s.full_name }));

  const ids = (events ?? []).map((e) => e.id);
  const { data: slots } = ids.length ? await supabase.from('ptm_slot').select('id, event_id').in('event_id', ids) : { data: [] };
  const { data: bookings } = ids.length
    ? await supabase
        .from('ptm_booking')
        .select('id, event_id, status, slot:slot_id(starts_at), student:student_id(name_en, gr_number), teacher:teacher_id(full_name), guardian:guardian_id(name_en)')
        .in('event_id', ids)
        .eq('status', 'confirmed')
        .order('booked_at')
    : { data: [] };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Parent-teacher meetings</h1>
        <p className="text-sm text-muted-foreground">
          FR-N11 — open a PTM, generate slots for the teachers taking part and let parents book from the portal. A slot can be held by one family only; booking closes at the cutoff; each child gets one slot per teacher.
        </p>
      </div>

      {campusId && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">New PTM</CardTitle>
          </CardHeader>
          <CardContent>
            <EventForm campusId={campusId} />
          </CardContent>
        </Card>
      )}

      {(events ?? []).length === 0 && <p className="text-sm text-muted-foreground">No PTM has been set up yet.</p>}
      {(events ?? []).map((e) => {
        const eventSlots = (slots ?? []).filter((s) => s.event_id === e.id).length;
        const eventBookings = (bookings ?? []).filter((b) => b.event_id === e.id);
        return (
          <Card key={e.id} data-testid="ptm-event">
            <CardHeader>
              <CardTitle className="flex flex-wrap items-center justify-between gap-2 text-base">
                <span>
                  {e.title} · {e.event_date}
                </span>
                <span className="flex gap-2">
                  <Badge variant="outline">{eventSlots} slots</Badge>
                  <Badge variant="success">{eventBookings.length} booked</Badge>
                </span>
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4 text-sm">
              <p className="text-muted-foreground">
                {e.booking_opens_at ? `Booking opens ${fmt(e.booking_opens_at)}. ` : ''}Booking closes {fmt(e.booking_cutoff_at)}. {e.slot_minutes}-minute slots.
              </p>
              <SlotsForm eventId={e.id} teachers={teachers} />
              <table className="w-full text-left" data-testid="ptm-bookings">
                <thead>
                  <tr className="border-b text-muted-foreground">
                    <th className="py-1">Time</th>
                    <th>Teacher</th>
                    <th>Student</th>
                    <th>Parent</th>
                  </tr>
                </thead>
                <tbody>
                  {eventBookings.length === 0 && (
                    <tr>
                      <td colSpan={4} className="py-2 text-muted-foreground">
                        No bookings yet.
                      </td>
                    </tr>
                  )}
                  {[...eventBookings]
                    .sort((a, b) => (one(a.slot)?.starts_at ?? '').localeCompare(one(b.slot)?.starts_at ?? ''))
                    .map((b) => (
                      <tr key={b.id} className="border-b" data-testid="ptm-booking-row">
                        <td className="py-1">{one(b.slot)?.starts_at ? fmt(one(b.slot)!.starts_at) : ''}</td>
                        <td>{one(b.teacher)?.full_name}</td>
                        <td>
                          {one(b.student)?.name_en} ({one(b.student)?.gr_number})
                        </td>
                        <td>{one(b.guardian)?.name_en}</td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}

import { supabaseServer } from '@/lib/supabase/server';

export const metadata = {
  title: 'School Events Calendar | Parent Portal',
};

export default async function PortalCalendarPage() {
  const supabase = await supabaseServer();
  const client = supabase as any;

  // Query effective events for active children's campuses (RLS enforced)
  const { data: events } = await client
    .from('v_effective_campus_events')
    .select('*')
    .eq('is_cancelled', false)
    .order('starts_at', { ascending: true });

  const activeEvents = events || [];

  return (
    <div className="space-y-6">
      <div className="border-b pb-4 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h2 className="text-xl font-bold tracking-tight text-foreground">Campus Events & Holidays Calendar</h2>
          <p className="text-sm text-muted-foreground">
            Official holidays, exam schedules, and parent-teacher meetings for your enrolled children.
          </p>
        </div>
      </div>

      {activeEvents.length === 0 ? (
        <div className="p-8 text-center rounded-lg border bg-card text-muted-foreground">
          <p className="text-sm font-medium">No upcoming events or holidays scheduled at this time.</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {activeEvents.map((ev: any, idx: number) => {
            const isHoliday = ev.event_type === 'holiday';
            const isExam = ev.event_type === 'exam';
            const isPtm = ev.event_type === 'ptm';

            return (
              <div
                key={`${ev.event_id}-${idx}`}
                className={`p-5 rounded-lg border bg-card text-card-foreground shadow-sm space-y-2.5 ${
                  isHoliday ? 'border-red-200 dark:border-red-900/40 bg-red-50/20' : ''
                }`}
              >
                <div className="flex items-start justify-between gap-2">
                  <div className="space-y-1">
                    <span
                      className={`inline-flex items-center px-2 py-0.5 rounded text-[11px] font-semibold uppercase tracking-wider ${
                        isHoliday
                          ? 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300'
                          : isExam
                          ? 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300'
                          : isPtm
                          ? 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-300'
                          : 'bg-muted text-muted-foreground'
                      }`}
                    >
                      {ev.event_type}
                    </span>
                    <h3 className="font-semibold text-base text-foreground flex items-center gap-1.5">
                      {ev.title}
                      {ev.hijri_label && (
                        <span className="text-xs px-1.5 py-0.5 rounded font-normal bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-300">
                          {ev.hijri_label}
                        </span>
                      )}
                    </h3>
                  </div>
                </div>

                <div className="text-xs text-muted-foreground flex items-center gap-2">
                  <span>📅</span>
                  <span>
                    {new Date(ev.starts_at).toLocaleDateString([], {
                      weekday: 'short',
                      month: 'short',
                      day: 'numeric',
                      year: 'numeric',
                    })}
                    {new Date(ev.ends_at).toDateString() !== new Date(ev.starts_at).toDateString() && (
                      <span>
                        {' '}
                        to{' '}
                        {new Date(ev.ends_at).toLocaleDateString([], {
                          weekday: 'short',
                          month: 'short',
                          day: 'numeric',
                          year: 'numeric',
                        })}
                      </span>
                    )}
                  </span>
                  <span>•</span>
                  <span>{ev.is_all_day ? 'All Day' : new Date(ev.starts_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
                </div>

                {ev.description && (
                  <p className="text-xs text-muted-foreground whitespace-pre-line pt-1">
                    {ev.description}
                  </p>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

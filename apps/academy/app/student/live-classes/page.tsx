import { supabaseServer } from '@/lib/supabase/server';
import { formatDateTimePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { JoinButton } from './join-button';

export const dynamic = 'force-dynamic';

export default async function StudentLiveClassesPage() {
  const supabase = await supabaseServer();
  const { data: classes } = await supabase.rpc('my_live_classes');
  const now = Date.now();
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Live classes</h1>
      {(classes ?? []).length === 0 && <p className="text-sm text-muted-foreground">No live classes scheduled.</p>}
      <ul className="space-y-2">
        {(classes ?? []).map((c) => {
          const start = Date.parse(c.starts_at);
          const open = now >= start - 15 * 60_000 && now <= start + c.duration_min * 60_000;
          return (
            <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 rounded-md border p-3" data-testid="student-live-class">
              <div>
                <p className="font-medium">{c.title}</p>
                <p className="text-xs text-muted-foreground">
                  {c.subject ? `${c.subject} · ` : ''}
                  {formatDateTimePk(c.starts_at)} · {c.duration_min} minutes
                </p>
              </div>
              {c.cancelled ? (
                <Badge variant="outline">Cancelled</Badge>
              ) : c.joined && !open ? (
                <Badge variant="success">Attended</Badge>
              ) : open ? (
                <JoinButton id={c.id} />
              ) : (
                <Badge variant="outline">{now < start ? 'Opens 15 minutes before' : 'Missed'}</Badge>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { formatDateTimePk } from '@/lib/dates';
import { FOLLOWUP_CHANNEL_LABEL, FOLLOWUP_OUTCOME_LABEL } from '@/lib/validation';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CompleteFollowupControl } from './complete-followup-control';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function FollowupsPage() {
  const supabase = await supabaseServer();
  const select = 'id, channel, due_at, outcome, outcome_note, completed_at, enquiry:enquiry_id(enquiry_no, child_name, phone_e164, status)';
  const [{ data: open }, { data: done }] = await Promise.all([
    // Once the enquiry has become an application there is nothing left to chase.
    supabase
      .from('admission_followup')
      .select('id, channel, due_at, outcome, outcome_note, completed_at, enquiry:enquiry_id!inner(enquiry_no, child_name, phone_e164, status)')
      .is('completed_at', null)
      .eq('enquiry.status', 'open')
      .order('due_at')
      .limit(300),
    supabase.from('admission_followup').select(select).not('completed_at', 'is', null).order('completed_at', { ascending: false }).limit(30),
  ]);
  const now = Date.now();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Follow-ups</h1>
        <p className="text-sm text-muted-foreground">
          Calls and messages to parents who enquired. Schedule one from{' '}
          <Link href="/admissions/enquiries" className="underline">
            Enquiries
          </Link>
          ; mark it done here with what happened.
        </p>
      </div>

      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base">To do ({open?.length ?? 0})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          {(open ?? []).length === 0 && <p className="text-sm text-muted-foreground">Nothing to follow up.</p>}
          {(open ?? []).map((f) => {
            const e = one(f.enquiry);
            const overdue = new Date(f.due_at).getTime() < now;
            return (
              <div key={f.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3" data-testid={`followup-${e?.enquiry_no}`}>
                <div className="text-sm">
                  <p className="font-medium">
                    {e?.child_name} <span className="text-muted-foreground">({e?.enquiry_no})</span>
                  </p>
                  <p className="text-muted-foreground">
                    {FOLLOWUP_CHANNEL_LABEL[f.channel]} · {e?.phone_e164} · {formatDateTimePk(f.due_at)}{' '}
                    {overdue && <Badge variant="destructive">Overdue</Badge>}
                  </p>
                </div>
                <CompleteFollowupControl followupId={f.id} enquiryNo={e?.enquiry_no ?? ''} />
              </div>
            );
          })}
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base">Recently done</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm">
          {(done ?? []).length === 0 && <p className="text-muted-foreground">None yet.</p>}
          {(done ?? []).map((f) => {
            const e = one(f.enquiry);
            return (
              <p key={f.id} data-testid={`followup-done-${e?.enquiry_no}`}>
                <span className="font-medium">{e?.child_name}</span> · {f.outcome ? FOLLOWUP_OUTCOME_LABEL[f.outcome] : ''}
                {f.outcome_note ? ` · ${f.outcome_note}` : ''}
                <span className="text-muted-foreground"> · {formatDateTimePk(f.completed_at!)}</span>
              </p>
            );
          })}
        </CardContent>
      </Card>
    </div>
  );
}

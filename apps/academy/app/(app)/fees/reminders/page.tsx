import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RuleToggle, SeedButton } from './rule-controls';

export default async function RemindersPage() {
  const supabase = await supabaseServer();
  const [rulesRes, logRes, taskRes] = await Promise.all([
    supabase.from('fee_reminder_rule').select('id, rung_code, offset_days, channel, template_code, is_active').order('offset_days'),
    supabase.from('fee_reminder_log').select('id, rung_code, channel, status, created_at').order('created_at', { ascending: false }).limit(30),
    supabase.from('fee_follow_up_task').select('id, rung_code, summary, total_due_paisa, created_at').eq('status', 'open').order('created_at', { ascending: false }).limit(30),
  ]);
  const rules = rulesRes.data ?? [];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee reminders</h1>
        <p className="text-sm text-muted-foreground">
          FR-K26 — the ladder runs daily at 09:00. A guardian gets one consolidated message across all their children; a paid challan stops its ladder; quiet hours defer sending to 08:00.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Ladder</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          {rules.length === 0 ? (
            <SeedButton />
          ) : (
            rules.map((r) => (
              <div key={r.id} className="flex items-center justify-between border-b py-2" data-testid="reminder-rule">
                <span>
                  Day {r.offset_days} · {r.channel} · {r.rung_code}
                  {r.template_code ? ` · template ${r.template_code}` : ''}
                </span>
                <span className="flex items-center gap-3">
                  <Badge variant={r.is_active ? 'success' : 'outline'}>{r.is_active ? 'active' : 'paused'}</Badge>
                  <RuleToggle ruleId={r.id} active={r.is_active} />
                </span>
              </div>
            ))
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Open follow-up calls ({(taskRes.data ?? []).length})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="follow-up-tasks">
          {(taskRes.data ?? []).length === 0 && <p className="text-muted-foreground">No calls to make.</p>}
          {(taskRes.data ?? []).map((t) => (
            <p key={t.id}>
              {t.summary} — PKR {(Number(t.total_due_paisa) / 100).toLocaleString('en-PK')}
            </p>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Recent reminders</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="reminder-log">
          {(logRes.data ?? []).length === 0 && <p className="text-muted-foreground">Nothing sent yet.</p>}
          {(logRes.data ?? []).map((l) => (
            <p key={l.id} className="flex justify-between border-b py-1">
              <span>
                {l.rung_code} · {l.channel}
              </span>
              <span className="text-muted-foreground">
                {l.status.replace(/_/g, ' ')} · {new Date(l.created_at).toLocaleString()}
              </span>
            </p>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

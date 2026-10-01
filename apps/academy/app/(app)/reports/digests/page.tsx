import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SubscribeForm, SubscriptionActions } from './digest-forms';

const CHANNEL: Record<string, string> = { in_app: 'In the app', whatsapp: 'WhatsApp', sms: 'SMS', email: 'Email' };
const STATUS_LABEL: Record<string, string> = { pending: 'queued', sent: 'sent', failed: 'failed', skipped_empty: 'skipped (nothing to report)', cancelled: 'cancelled' };

export default async function DigestsPage() {
  const supabase = await supabaseServer();
  const [reportsRes, subsRes, templatesRes] = await Promise.all([
    supabase.from('digest_report').select('report_key, display_name, allowed_roles').order('display_name'),
    supabase.from('v_report_subscription_status').select('*').order('run_at_local'),
    supabase.from('wa_template').select('id, meta_template_name, language, status, variable_count, report_key').not('report_key', 'is', null).order('meta_template_name'),
  ]);
  const reports = (reportsRes.data ?? []).map((r) => ({ key: r.report_key, label: r.display_name }));
  const subs = subsRes.data ?? [];
  const templates = templatesRes.data ?? [];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Scheduled digests</h1>
        <p className="text-sm text-muted-foreground">FR-S05 — get a summary at a fixed time without logging in. Times are local to the timezone you choose. If a report has nothing to say, nothing is sent.</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">New subscription</CardTitle>
        </CardHeader>
        <CardContent>
          <SubscribeForm reports={reports} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">WhatsApp templates available to digests</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="wa-templates">
          {templates.length === 0 && <p className="text-muted-foreground">No WhatsApp template is registered for digests, so WhatsApp cannot be chosen yet. SMS, email and in-app delivery still work.</p>}
          {templates.map((t) => (
            <p key={t.id}>
              <strong>{t.meta_template_name}</strong> ({t.language}) · {t.variable_count} variables · <Badge variant={t.status === 'APPROVED' ? 'success' : 'outline'}>{t.status.toLowerCase()}</Badge>
            </p>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Your subscriptions</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="subscriptions">
          {subs.length === 0 && <p className="text-muted-foreground">No subscriptions yet.</p>}
          {subs.map((s) => (
            <div key={s.id} className="space-y-1 border-b pb-3" data-testid="subscription-row">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium">
                  {s.display_name} · {s.cadence} at {String(s.run_at_local).slice(0, 5)} ({s.timezone}) · {CHANNEL[s.channel ?? ''] ?? s.channel}
                </span>
                <span className="flex items-center gap-2">
                  <Badge variant={s.is_active ? 'success' : 'outline'}>{s.is_active ? 'active' : 'paused'}</Badge>
                  <SubscriptionActions id={s.id!} active={Boolean(s.is_active)} />
                </span>
              </div>
              {s.last_status && (
                <p className="text-xs text-muted-foreground" data-testid="last-delivery">
                  Last: {STATUS_LABEL[s.last_status] ?? s.last_status}
                  {s.last_scheduled_for ? ` for ${new Date(s.last_scheduled_for).toLocaleString('en-PK', { timeZone: s.timezone ?? 'Asia/Karachi' })}` : ''}
                  {s.last_attempt_no && s.last_attempt_no > 1 ? ` (attempt ${s.last_attempt_no})` : ''}
                  {s.last_was_fallback && s.last_channel_used ? ` — sent by ${CHANNEL[s.last_channel_used] ?? s.last_channel_used} because WhatsApp could not deliver` : ''}
                </p>
              )}
              {s.last_status === 'failed' && s.last_error && (
                <p role="alert" className="text-xs text-destructive" data-testid="last-error">
                  Delivery failed: {s.last_error}
                </p>
              )}
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

import { supabaseServer } from '@/lib/supabase/server';
import { ReminderList, type ReminderRow } from './reminder-list';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function RemindersPage() {
  const supabase = await supabaseServer();

  const { data: rows } = await supabase
    .from('outbound_message')
    .select('id, reminder_kind, channel, locale, to_phone, template_id, status, failure_code, created_at, admission_enquiry(child_name)')
    .order('created_at', { ascending: false });

  const reminders: ReminderRow[] = (rows ?? []).map((r) => ({
    id: r.id,
    childName: one(r.admission_enquiry)?.child_name ?? 'Unknown',
    reminderKind: r.reminder_kind,
    channel: r.channel,
    locale: r.locale,
    toPhone: r.to_phone,
    templateId: r.template_id,
    status: r.status,
    failureCode: r.failure_code,
    createdAt: r.created_at,
  }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Reminders</h1>
        <p className="text-sm text-muted-foreground">
          FR-B05 — queue WhatsApp/SMS follow-up and appointment reminders. No pg_cron locally, so the
          queue is checked manually here instead of on a schedule.
        </p>
      </div>
      <ReminderList reminders={reminders} />
    </div>
  );
}

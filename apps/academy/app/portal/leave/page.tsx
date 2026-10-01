import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t, type MessageKey } from '@/lib/i18n/messages';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CancelLeaveButton, LeaveForm } from './leave-form';

export const metadata = { title: 'Leave | Parent Portal' };

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function PortalLeavePage() {
  const supabase = await supabaseServer();
  const lang = await getLang();

  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student:student_id(name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');
  const children = (enrolments ?? []).map((e) => {
    const student = one(e.student);
    const section = one(e.class_section);
    const level = section ? one(section.class_level) : null;
    return { enrolmentId: e.id, label: `${student?.name_en ?? ''} · ${level?.name_en ?? ''} ${section?.name ?? ''}`.trim() };
  });
  const nameByEnrolment = new Map(children.map((c) => [c.enrolmentId, c.label]));

  const { data: applications } = await supabase
    .from('student_leave_application')
    .select('id, enrolment_id, from_date, to_date, reason_category, remarks, status, created_at, attachments:student_leave_attachment(id, file_name)')
    .order('created_at', { ascending: false })
    .limit(30);

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-base">{t(lang, 'leave.title')}</CardTitle>
        </CardHeader>
        <CardContent>
          <LeaveForm lang={lang} students={children} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{t(lang, 'leave.mine')}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="leave-list">
          {(applications ?? []).length === 0 && <p className="text-muted-foreground">{t(lang, 'leave.none')}</p>}
          {(applications ?? []).map((a) => (
            <div key={a.id} className="space-y-1 border-b pb-3" data-testid="leave-row">
              <div className="flex items-center justify-between gap-2">
                <span className="font-medium">{nameByEnrolment.get(a.enrolment_id) ?? ''}</span>
                <Badge variant={a.status === 'approved' ? 'success' : a.status === 'rejected' ? 'destructive' : 'outline'}>{t(lang, `leave.status.${a.status}` as MessageKey)}</Badge>
              </div>
              <p>
                {a.from_date} → {a.to_date} · {t(lang, `leave.cat.${a.reason_category}` as MessageKey)}
              </p>
              {a.remarks && (
                <p dir="auto" className="text-muted-foreground">
                  {a.remarks}
                </p>
              )}
              {(a.attachments ?? []).length > 0 && <p className="text-xs text-muted-foreground">{(a.attachments ?? []).map((f) => f.file_name).join(', ')}</p>}
              {a.status === 'pending' && <CancelLeaveButton lang={lang} leaveId={a.id} />}
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

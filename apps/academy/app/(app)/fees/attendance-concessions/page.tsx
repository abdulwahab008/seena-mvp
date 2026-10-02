import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RefreshButton, ResolveForm, ThresholdForm } from './controls';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const REASON: Record<string, string> = { meets_threshold: 'meets the threshold', below_threshold: 'below the threshold', no_attendance_data: 'no attendance data yet' };

export default async function AttendanceConcessionsPage() {
  const supabase = await supabaseServer();
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const year = Number(today.slice(0, 4));
  const month = Number(today.slice(5, 7));

  const [schemeRes, flagRes, taskRes] = await Promise.all([
    supabase.from('concession_scheme').select('id, code, name_en, min_attendance_pct').eq('is_active', true).order('code'),
    supabase
      .from('v_attendance_concession_eligibility')
      .select('award_id, enrolment_id, scheme_code, attendance_pct, required_pct, attendance_eligible, reason_code, computed_at')
      .eq('billing_year', year)
      .eq('billing_month', month)
      .order('attendance_eligible'),
    supabase
      .from('attendance_eligibility_adjustment')
      .select('id, enrolment_id, old_flag, new_flag, old_pct, new_pct, challan_id, created_at, challan:challan_id(challan_no, net_paisa)')
      .eq('status', 'open')
      .order('created_at', { ascending: false }),
  ]);
  const flags = flagRes.data ?? [];
  const tasks = taskRes.data ?? [];
  const enrolIds = [...new Set([...flags.map((f) => f.enrolment_id), ...tasks.map((t) => t.enrolment_id)].filter((v): v is string => Boolean(v)))];
  const { data: enrols } = enrolIds.length ? await supabase.from('enrolment').select('id, student:student_id(name_en, gr_number)').in('id', enrolIds) : { data: [] };
  const students = new Map((enrols ?? []).map((e) => [e.id, one(e.student)]));
  const label = (id: string | null) => {
    const s = id ? students.get(id) : null;
    return s ? `${s.name_en} · GR ${s.gr_number}` : 'Student';
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Attendance-linked concessions</h1>
          <p className="text-sm text-muted-foreground">
            FR-G17 — a scheme with a minimum attendance applies to a month&apos;s challan only if the student met it last month. A student with no attendance data keeps the concession. An issued challan is never changed: if attendance is corrected afterwards, an adjustment task is raised here.
          </p>
        </div>
        <RefreshButton />
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Scheme thresholds</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="scheme-thresholds">
          {(schemeRes.data ?? []).length === 0 && <p className="text-muted-foreground">No concession schemes yet.</p>}
          {(schemeRes.data ?? []).map((s) => (
            <div key={s.id} className="flex items-center justify-between border-b py-1">
              <span>
                {s.code} — {s.name_en}
              </span>
              <ThresholdForm schemeId={s.id} current={s.min_attendance_pct === null ? null : Number(s.min_attendance_pct)} />
            </div>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Adjustment tasks ({tasks.length})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="adjustment-tasks">
          {tasks.length === 0 && <p className="text-muted-foreground">Nothing to adjust.</p>}
          {tasks.map((t) => {
            const challan = one(t.challan);
            return (
              <div key={t.id} className="space-y-1 border-b pb-3" data-testid="adjustment-task">
                <p>
                  {label(t.enrolment_id)} — attendance moved {t.old_pct ?? 'n/a'}% → {t.new_pct ?? 'n/a'}%, so the concession should now be {t.new_flag ? 'applied' : 'withheld'}. Challan {challan?.challan_no ?? ''} ({challan ? pkr(Number(challan.net_paisa)) : ''}) was already issued and is unchanged.
                </p>
                <ResolveForm taskId={t.id} />
              </div>
            );
          })}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            Eligibility for {String(month).padStart(2, '0')}/{year}
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="eligibility-list">
          {flags.length === 0 && <p className="text-muted-foreground">No flags yet for this month. They are settled overnight, or press refresh.</p>}
          {flags.map((f) => (
            <div key={f.award_id} className="flex justify-between border-b py-1" data-testid="eligibility-row">
              <span>
                {label(f.enrolment_id)} · {f.scheme_code}
              </span>
              <span className="flex items-center gap-2">
                {f.attendance_pct === null ? 'n/a' : `${f.attendance_pct}%`} of {f.required_pct}% — {REASON[f.reason_code ?? ''] ?? f.reason_code}
                <Badge variant={f.attendance_eligible ? 'success' : 'destructive'}>{f.attendance_eligible ? 'eligible' : 'withheld'}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

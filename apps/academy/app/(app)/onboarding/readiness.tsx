import Link from 'next/link';
import { CheckCircle2, CircleDashed } from 'lucide-react';
import { supabaseServer } from '@/lib/supabase/server';

type Check = { label: string; why: string; href: string; done: boolean };

// Each of these blocks a feature with an error only once someone is halfway through a task
// (timetable auto-fill, results, certificates, cash, SMS). Listing them in one place, read live
// from the data, saves finding them one failed click at a time.
export async function SetupReadiness({ campusId }: { campusId: string }) {
  const supabase = await supabaseServer();
  const count = (r: { count: number | null }) => (r.count ?? 0) > 0;

  const [bells, curriculum, grading, terms, tcTemplate, signing, counter, admissionFee, departments, rooms, sms] = await Promise.all([
    supabase.from('bell_template').select('id', { count: 'exact', head: true }).eq('campus_id', campusId).eq('is_default', true),
    supabase.from('class_subject').select('id', { count: 'exact', head: true }).eq('campus_id', campusId),
    supabase.from('grading_scheme').select('id', { count: 'exact', head: true }).eq('status', 'active'),
    supabase.from('exam_term').select('id', { count: 'exact', head: true }).eq('campus_id', campusId).eq('status', 'active'),
    supabase.from('certificate_template').select('id', { count: 'exact', head: true }).eq('certificate_type', 'transfer').eq('status', 'active'),
    supabase.from('signing_identity').select('id', { count: 'exact', head: true }).eq('campus_id', campusId).is('valid_to', null),
    supabase.from('cash_counter').select('id', { count: 'exact', head: true }).eq('campus_id', campusId).eq('is_active', true),
    supabase
      .from('fee_structure_line')
      .select('id, fee_head!inner(code), fee_structure!inner(campus_id, status)', { count: 'exact', head: true })
      .eq('fee_head.code', 'ADMISSION')
      .eq('fee_structure.status', 'published')
      .eq('fee_structure.campus_id', campusId),
    supabase.from('department').select('id', { count: 'exact', head: true }),
    supabase.from('room').select('id', { count: 'exact', head: true }).eq('campus_id', campusId),
    supabase.rpc('sms_gateway_settings'),
  ]);

  const checks: Check[] = [
    { label: 'Default bell timings', why: 'Timetable auto-fill and attendance windows', href: '/academic-setup/bell-templates', done: count(bells) },
    { label: 'Subjects mapped to classes', why: 'Homework, exams, timetable', href: '/academic-setup/curriculum', done: count(curriculum) },
    { label: 'Rooms', why: 'Timetable rooms and exam halls', href: '/academic-setup/rooms', done: count(rooms) },
    { label: 'Active exam term', why: 'Mark entry', href: '/exams/terms', done: count(terms) },
    { label: 'Active grading scale', why: 'Results and report cards', href: '/exams/grading', done: count(grading) },
    { label: 'Admission fee in the fee structure', why: 'Pre-fills offers and walk-in admissions', href: '/fees/structure', done: count(admissionFee) },
    { label: 'Cash counter', why: 'Taking cash at the counter and walk-in', href: '/fees/counter', done: count(counter) },
    { label: 'Transfer certificate template', why: 'Issuing TCs', href: '/certificates/templates', done: count(tcTemplate) },
    { label: 'Certificate signatory', why: 'Signature on every certificate', href: '/certificates/signing', done: count(signing) },
    { label: 'SMS gateway', why: 'Absentee alerts, fee reminders, circulars', href: '/communication/sms-gateway', done: (sms.data ?? []).some((g) => g.is_active && g.has_key) },
    { label: 'Departments', why: 'Staff records and HR reports', href: '/staff/departments', done: count(departments) },
  ];
  const missing = checks.filter((c) => !c.done).length;

  return (
    <section className="space-y-3 rounded-lg border p-4" data-testid="setup-readiness">
      <div>
        <h2 className="font-semibold">Ready to run</h2>
        <p className="text-sm text-muted-foreground">
          {missing === 0 ? 'Everything the day-to-day screens depend on is in place.' : `${missing} of ${checks.length} still to set up. Each is checked from your data, so it ticks itself once done.`}
        </p>
      </div>
      <ul className="divide-y text-sm">
        {checks.map((c) => (
          <li key={c.href} className="flex items-center justify-between gap-3 py-2">
            <span className="flex items-center gap-2">
              {c.done ? <CheckCircle2 className="h-4 w-4 text-green-600" /> : <CircleDashed className="h-4 w-4 text-muted-foreground" />}
              <span>
                <span className="font-medium">{c.label}</span>
                <span className="text-muted-foreground"> · {c.why}</span>
              </span>
            </span>
            {!c.done && (
              <Link href={c.href} className="shrink-0 underline">
                Set up
              </Link>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

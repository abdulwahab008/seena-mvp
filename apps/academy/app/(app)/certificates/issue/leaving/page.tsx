import { supabaseServer } from '@/lib/supabase/server';
import { certificateDownloadPath } from '@/lib/certificates/issue';
import { IssueLeavingCertificate, type LeaverOption, type LeavingIssued, type LeavingTemplate } from './leaving-form';

// Mirrors issue_leaving_certificate()'s own role gate; the database enforces it.
const ISSUE_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller'];
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function IssueLeavingCertificatePage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const canIssue = ISSUE_ROLES.includes(appUser?.app_role ?? 'none');

  let leavers: LeaverOption[] = [];
  let templates: LeavingTemplate[] = [];
  let issued: LeavingIssued[] = [];

  if (canIssue) {
    const [{ data: enrolments }, { data: templateRows }, { data: issueRows }] = await Promise.all([
      // Only Grade 10 and 12 enrolments of students who finished or were struck off: the database decides who is eligible.
      supabase
        .from('enrolment')
        .select('id, student:student_id(name_en, gr_number, status), class_level!inner(code, name_en)')
        .in('class_level.code', ['10', '12'])
        .in('status', ['graduated', 'left', 'active'])
        .is('deleted_at', null)
        .order('joined_on', { ascending: false })
        .limit(300),
      supabase.from('certificate_template').select('id, board_code, language, version, title').eq('certificate_type', 'leaving').eq('status', 'active').order('board_code'),
      supabase
        .from('certificate_issue')
        .select('id, serial_no, status, payload_snapshot, student:student_id(name_en, gr_number)')
        .eq('certificate_type', 'leaving')
        .order('issued_at', { ascending: false })
        .limit(50),
    ]);

    leavers = (enrolments ?? []).map((e) => {
      const s = one(e.student);
      const c = one(e.class_level);
      return { id: e.id, label: `${s?.name_en ?? ''} (${s?.gr_number ?? ''}) · ${c?.name_en ?? ''} · ${(s?.status ?? '').replace('_', ' ')}` };
    });
    templates = (templateRows ?? []).map((t) => ({ value: `${t.board_code ?? '_any'}|${t.language}`, label: `${t.board_code ?? 'Any board'} · ${t.language === 'ur' ? 'اردو' : 'English'} · v${t.version} — ${t.title}` }));
    issued = (issueRows ?? []).map((r) => ({
      id: r.id,
      serial_no: r.serial_no,
      status: r.status,
      student: `${one(r.student)?.name_en ?? ''} (${one(r.student)?.gr_number ?? ''})`,
      result: String((r.payload_snapshot as { values?: Record<string, string> } | null)?.values?.['leaving.result_status'] ?? ''),
      downloadUrl: r.status === 'issued' ? certificateDownloadPath(r.id) : null,
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Issue a School Leaving Certificate</h1>
        <p className="text-sm text-muted-foreground">
          FR-T07 — for a student who completed Grade 10 or 12, on its own serial series (SLC). It prints the board, roll number, group and class from the exam registration; until the board result is imported it states “Result Awaited” rather than leaving a blank. Students leaving any other class need a Transfer Certificate.
        </p>
      </div>
      {!canIssue ? (
        <p className="text-sm text-muted-foreground" data-testid="slc-forbidden">
          Only an Owner, Super Admin, Principal, Admissions Officer or Exam Controller can issue certificates.
        </p>
      ) : (
        <IssueLeavingCertificate leavers={leavers} templates={templates} issued={issued} />
      )}
    </div>
  );
}

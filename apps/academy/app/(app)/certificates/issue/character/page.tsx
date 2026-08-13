import { supabaseServer } from '@/lib/supabase/server';
import { certificateDownloadPath } from '@/lib/certificates/issue';
import { IssueCharacterCertificate, type IssuedRow, type StudentRow, type TemplateOption } from './issue-character-certificate';

// Matches cert_issue_campus_scope and issue_character_certificate()'s own
// role gate in 20260731890000_character_certificate_issuance.sql; the
// database is what actually enforces it.
const ISSUE_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer'];

export default async function IssueCharacterCertificatePage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canIssue = ISSUE_ROLES.includes(role);

  let students: StudentRow[] = [];
  let issued: IssuedRow[] = [];
  let templates: TemplateOption[] = [];

  if (canIssue) {
    const [{ data: studentRows }, { data: issueRows }, { data: templateRows }] = await Promise.all([
      // Every student on the books, not only the enrolled ones: a Character
      // Certificate is asked for precisely by the ones who have left.
      // Soft-deleted records are excluded (FR-A15), as the issuing function
      // refuses them anyway.
      supabase.from('student').select('id, name_en, gr_number, status').is('deleted_at', null).order('name_en').limit(500),
      supabase
        .from('certificate_issue')
        .select('id, serial_no, status, issued_at, pdf_path, revoke_reason, payload_snapshot, student:student_id(name_en, gr_number)')
        .eq('certificate_type', 'character')
        .order('issued_at', { ascending: false })
        .limit(50),
      supabase
        .from('certificate_template')
        .select('id, board_code, language, version, title')
        .eq('certificate_type', 'character')
        .eq('status', 'active')
        .order('board_code'),
    ]);

    students = (studentRows ?? []) as StudentRow[];
    templates = (templateRows ?? []) as TemplateOption[];

    const rows = (issueRows ?? []) as unknown as Omit<IssuedRow, 'downloadUrl'>[];
    // FR-T09: through the verifying route, not a signed bucket URL. A link
    // straight to storage is a link that hands over whatever the object
    // currently contains, which is exactly what the digest check exists to
    // catch.
    issued = rows.map((r) => ({ ...r, downloadUrl: r.status === 'issued' ? certificateDownloadPath(r.id) : null }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Issue a Character Certificate</h1>
        <p className="text-sm text-muted-foreground">
          FR-T05 — states the student&apos;s conduct and the period they actually attended, taken from their enrolment
          history rather than from today&apos;s date. Issuable to a student who has already left, on its own serial
          series, and as often as one is asked for.
        </p>
      </div>

      {!canIssue ? (
        <p className="text-sm text-muted-foreground" data-testid="cc-issue-forbidden">
          Only an Owner, Super Admin, Principal or Admissions Officer can issue certificates.
        </p>
      ) : (
        <IssueCharacterCertificate students={students} issued={issued} templates={templates} />
      )}
    </div>
  );
}

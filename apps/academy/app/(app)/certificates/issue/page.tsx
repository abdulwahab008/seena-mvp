import { supabaseServer } from '@/lib/supabase/server';
import { certificateDownloadPath } from '@/lib/certificates/issue';
import { IssueTransferCertificate, type CandidateRow, type IssuedRow, type TemplateOption } from './issue-transfer-certificate';

// Matches cert_issue_campus_scope and issue_transfer_certificate()'s own
// role gate in 20260731880000_transfer_certificate_issuance.sql; the
// database is what actually enforces it.
const ISSUE_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer'];

export default async function IssueCertificatePage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canIssue = ISSUE_ROLES.includes(role);

  let candidates: CandidateRow[] = [];
  let issued: IssuedRow[] = [];
  let templates: TemplateOption[] = [];

  if (canIssue) {
    const [{ data: enrolmentRows }, { data: issueRows }, { data: templateRows }] = await Promise.all([
      supabase
        .from('enrolment')
        .select('id, student:student_id(id, name_en, gr_number), class_level:class_level_id(name_en), section:section_id(name)')
        .eq('status', 'active')
        .is('deleted_at', null)
        .order('id')
        .limit(500),
      supabase
        .from('certificate_issue')
        .select('id, serial_no, status, issued_at, pdf_path, revoke_reason, student:student_id(name_en, gr_number)')
        .eq('certificate_type', 'transfer')
        .order('issued_at', { ascending: false })
        .limit(50),
      supabase
        .from('certificate_template')
        .select('id, board_code, language, version, title')
        .eq('certificate_type', 'transfer')
        .eq('status', 'active')
        .order('board_code'),
    ]);

    candidates = (enrolmentRows ?? []) as unknown as CandidateRow[];
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
        <h1 className="text-2xl font-semibold">Issue a Transfer Certificate</h1>
        <p className="text-sm text-muted-foreground">
          FR-T03 — a TC carries the student&apos;s GR number, dates, conduct and last class passed, takes its serial from the
          campus register and takes the student off the roster from the leaving date. One original per enrolment.
        </p>
      </div>

      {!canIssue ? (
        <p className="text-sm text-muted-foreground" data-testid="cert-issue-forbidden">
          Only an Owner, Super Admin, Principal or Admissions Officer can issue certificates.
        </p>
      ) : (
        <IssueTransferCertificate candidates={candidates} issued={issued} templates={templates} />
      )}
    </div>
  );
}

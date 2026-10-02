import { supabaseServer } from '@/lib/supabase/server';
import { CERTIFICATE_TYPES, type CertificateType } from '@/lib/validation';
import { readRegister } from '@/lib/certificates/register-query';
import { CertificateRegisterView } from './certificate-register-view';

/**
 * FR-T08. The register is what a Principal produces during an inspection,
 * so the UI is theirs: cert_issue_campus_scope also lets an Admissions
 * Officer READ certificate rows (they issue them), but only a Principal,
 * Owner or Super Admin may strike an entry out, and this page is the
 * surface where that happens. The same narrowing the Audit Export page
 * (FR-T14) and the Recycle Bin (FR-A15) already apply.
 */
const REGISTER_ROLES = ['super_admin', 'owner', 'principal'];

type SearchParams = { type?: string; year?: string; campus?: string };

function parseType(value: string | undefined): CertificateType {
  return (CERTIFICATE_TYPES as readonly string[]).includes(value ?? '') ? (value as CertificateType) : 'transfer';
}

export default async function CertificateRegisterPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canView = REGISTER_ROLES.includes(role);

  if (!canView) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Statutory certificate register</h1>
        <p className="text-sm text-muted-foreground" data-testid="cert-register-forbidden">
          Only an Owner, Super Admin or Principal can open the certificate register.
        </p>
      </div>
    );
  }

  const [{ data: campusRows }, { data: sessionRows }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('starts_on').order('starts_on', { ascending: false }),
  ]);
  const campuses = campusRows ?? [];

  // The years the register can actually be asked about are the years the
  // school has sessions for; a year with no session can hold no serial.
  const years = [...new Set((sessionRows ?? []).map((s) => new Date(s.starts_on).getUTCFullYear()))].sort((a, b) => b - a);
  const currentYear = new Date().getFullYear();
  const yearOptions = years.length > 0 ? years : [currentYear];

  const requestedYear = Number(params.year);
  const filters = {
    campusId: campuses.some((c) => c.id === params.campus) ? params.campus! : '',
    certificateType: parseType(params.type),
    academicYear: yearOptions.includes(requestedYear) ? requestedYear : (yearOptions[0] ?? currentYear),
  };

  const { rows, continuity } = await readRegister(supabase, filters);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Statutory certificate register</h1>
        <p className="text-sm text-muted-foreground">
          FR-T08 — every certificate this campus ever issued, in serial order and written once. A cancelled entry keeps its
          number and stays in sequence with its reason and the serial that replaced it; nothing here can be edited or deleted,
          by anyone.
        </p>
      </div>

      <CertificateRegisterView
        campuses={campuses}
        yearOptions={yearOptions}
        filters={filters}
        rows={rows}
        continuity={continuity}
      />
    </div>
  );
}

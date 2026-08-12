import { supabaseServer } from '@/lib/supabase/server';

// Matches serial_counter_read in
// 20260731870000_certificate_serial_allocation.sql; the database is what
// actually enforces it, and a Principal only ever sees their own campuses.
const REGISTER_ROLES = ['super_admin', 'owner', 'principal'];

const TYPE_LABELS: Record<string, string> = {
  transfer: 'Transfer Certificate',
  character: 'Character Certificate',
  bonafide: 'Bonafide Certificate',
};

type SerialSeries = {
  campus_id: string;
  campus_code: string;
  campus_name: string;
  certificate_type: string;
  session_id: string;
  session_name: string;
  academic_year: number;
  prefix_pattern: string;
  current_value: number;
  last_serial: string | null;
  next_serial: string;
  last_allocated_at: string | null;
};

export default async function CertificateSerialsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canView = REGISTER_ROLES.includes(role);

  let series: SerialSeries[] = [];
  if (canView) {
    const { data } = await supabase
      .from('v_certificate_serial_register')
      .select(
        'campus_id, campus_code, campus_name, certificate_type, session_id, session_name, academic_year, prefix_pattern, current_value, last_serial, next_serial, last_allocated_at',
      )
      .order('campus_code')
      .order('academic_year', { ascending: false })
      .order('certificate_type');
    series = (data ?? []) as SerialSeries[];
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Certificate serial register</h1>
        <p className="text-sm text-muted-foreground">
          FR-T02 — one unbroken run of numbers per campus, certificate type and academic year. Counters are advanced only
          by issuing a certificate; nobody, including a Super Admin, can edit one by hand.
        </p>
      </div>

      {!canView ? (
        <p className="text-sm text-muted-foreground" data-testid="cert-serial-forbidden">
          Only an Owner, Super Admin or Principal can view the certificate serial register.
        </p>
      ) : series.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="cert-serial-empty">
          No certificate has been issued yet. A series is created by the first certificate of its type and year.
        </p>
      ) : (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50">
                <th className="p-2 text-left font-medium">Campus</th>
                <th className="p-2 text-left font-medium">Certificate</th>
                <th className="p-2 text-left font-medium">Academic year</th>
                <th className="p-2 text-left font-medium">Format</th>
                <th className="p-2 text-right font-medium">Issued</th>
                <th className="p-2 text-left font-medium">Last serial</th>
                <th className="p-2 text-left font-medium">Next serial</th>
              </tr>
            </thead>
            <tbody>
              {series.map((s) => (
                <tr
                  key={`${s.campus_id}-${s.certificate_type}-${s.session_id}`}
                  className="border-b last:border-0"
                  data-testid={`cert-serial-row-${s.campus_code}-${s.certificate_type}`}
                >
                  <td className="p-2">
                    <span className="font-medium">{s.campus_code}</span>
                    <span className="ml-2 text-xs text-muted-foreground">{s.campus_name}</span>
                  </td>
                  <td className="p-2">{TYPE_LABELS[s.certificate_type] ?? s.certificate_type}</td>
                  <td className="p-2">
                    {s.academic_year}
                    <span className="ml-2 text-xs text-muted-foreground">{s.session_name}</span>
                  </td>
                  <td className="p-2 font-mono text-xs text-muted-foreground">{s.prefix_pattern}</td>
                  <td className="p-2 text-right tabular-nums" data-testid={`cert-serial-count-${s.campus_code}-${s.certificate_type}`}>
                    {s.current_value}
                  </td>
                  <td className="p-2 font-mono" data-testid={`cert-serial-last-${s.campus_code}-${s.certificate_type}`}>
                    {s.last_serial ?? '—'}
                  </td>
                  <td className="p-2 font-mono" data-testid={`cert-serial-next-${s.campus_code}-${s.certificate_type}`}>
                    {s.next_serial}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

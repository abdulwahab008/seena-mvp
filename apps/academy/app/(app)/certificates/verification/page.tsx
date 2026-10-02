import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';

const LABEL: Record<string, string> = { transfer: 'Transfer', character: 'Character', bonafide: 'Bonafide', leaving: 'Leaving' };

export default async function VerificationActivityPage() {
  const supabase = await supabaseServer();
  const [{ data: activity }, { data: recent }] = await Promise.all([
    supabase
      .from('v_certificate_verify_activity')
      .select('campus_id, day, certificate_type, serial_bucket_start, valid_scans, cancelled_scans, distinct_addresses, total_scans')
      .order('day', { ascending: false })
      .order('total_scans', { ascending: false })
      .limit(60),
    supabase.from('certificate_verify_log').select('id, verified_at, result').order('verified_at', { ascending: false }).limit(200),
  ]);
  const counts = (recent ?? []).reduce<Record<string, number>>((acc, r) => ({ ...acc, [r.result]: (acc[r.result] ?? 0) + 1 }), {});

  return (
    <div className="space-y-6">
      <PageHeader
        title="Certificate verification activity"
        description="FR-T10 — every scan of a certificate's QR code, from the public verification page. A burst of scans on one serial range, or many unknown codes, can be the first sign of forged certificates. Tokens and addresses are stored only as hashes."
      />
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Last 200 scans</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3 text-sm sm:grid-cols-4" data-testid="verify-counts">
          {(['valid', 'cancelled', 'not_found', 'rate_limited'] as const).map((k) => (
            <div key={k}>
              <p className="text-muted-foreground">{k.replace('_', ' ')}</p>
              <p className="text-lg font-semibold" data-testid={`verify-count-${k}`}>
                {counts[k] ?? 0}
              </p>
            </div>
          ))}
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">By day and serial range</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto text-sm">
          <table className="w-full" data-testid="verify-activity">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Day</th>
                <th>Type</th>
                <th>Serials</th>
                <th className="text-right">Valid</th>
                <th className="text-right">Cancelled</th>
                <th className="text-right">Addresses</th>
                <th className="text-right">Total</th>
              </tr>
            </thead>
            <tbody>
              {(activity ?? []).map((a, i) => (
                <tr key={i} className="border-t">
                  <td className="py-1">{a.day}</td>
                  <td>{LABEL[a.certificate_type ?? ''] ?? a.certificate_type}</td>
                  <td>
                    {a.serial_bucket_start}–{(a.serial_bucket_start ?? 0) + 49}
                  </td>
                  <td className="text-right">{a.valid_scans}</td>
                  <td className="text-right">{a.cancelled_scans}</td>
                  <td className="text-right">{a.distinct_addresses}</td>
                  <td className="text-right font-medium">{a.total_scans}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {(activity ?? []).length === 0 && <p className="text-muted-foreground">No certificate has been verified yet.</p>}
        </CardContent>
      </Card>
    </div>
  );
}

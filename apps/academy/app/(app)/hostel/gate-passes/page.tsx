import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ActionButton, SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus } from '@/lib/transport/rpc';
import { issuePass, returnPass } from './actions';

export const dynamic = 'force-dynamic';

type Pass = {
  id: string; serial: string; purpose: string; status: string; departs_at: string; expected_back_at: string; returned_at: string | null; override_reason: string | null;
  student: { name_en: string; gr_number: string } | { name_en: string; gr_number: string }[] | null;
};
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const fmt = (iso: string) => new Date(iso).toLocaleString('en-GB', { timeZone: 'Asia/Karachi', dateStyle: 'medium', timeStyle: 'short' });
const VARIANT = { open: 'primary', overdue: 'destructive', returned: 'success', cancelled: 'outline' } as const;

export default async function GatePassesPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const { data } = await supabase
    .from('hostel_gate_pass')
    .select('id, serial, purpose, status, departs_at, expected_back_at, returned_at, override_reason, student:student_id(name_en, gr_number)')
    .eq('campus_id', campus.id)
    .order('created_at', { ascending: false })
    .limit(60);
  const passes = (data ?? []) as Pass[];
  const canOverride = ['owner', 'super_admin', 'principal'].includes(role);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Gate passes</h1>
        <p className="text-sm text-muted-foreground">
          FR-Q03 — every exit is recorded against an approved pass. The collecting adult&apos;s CNIC must match a guardian; otherwise only a Principal can release the student, with a reason. Passes can&apos;t be edited.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Issue a pass</CardTitle>
        </CardHeader>
        <CardContent>
          <SpecForm
            testId="pass-form"
            submitLabel="Issue pass"
            action={issuePass}
            columns={3}
            fields={[
              { name: 'grNumber', label: 'Student GR number', required: true },
              { name: 'purpose', label: 'Purpose', required: true },
              { name: 'destination', label: 'Destination' },
              { name: 'departsAt', label: 'Leaves at', type: 'datetime-local', required: true },
              { name: 'expectedBackAt', label: 'Due back at', type: 'datetime-local', required: true },
              { name: 'collectorName', label: 'Collected by (name)', required: true },
              { name: 'collectorCnic', label: 'Collector CNIC', required: true, placeholder: '35202-1234567-1' },
              ...(canOverride ? [{ name: 'overrideReason', label: 'Principal override reason (only if the CNIC matches no guardian)', type: 'textarea' as const }] : []),
            ]}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Passes</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="pass-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Serial</th>
                <th>Student</th>
                <th>Purpose</th>
                <th>Due back</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {passes.map((p) => (
                <tr key={p.id} className="border-t" data-testid="pass-row">
                  <td className="py-1">
                    <Link className="font-medium hover:underline" href={`/hostel/gate-passes/${p.id}`}>
                      {p.serial}
                    </Link>
                  </td>
                  <td>
                    {one(p.student)?.name_en} <span className="text-muted-foreground">({one(p.student)?.gr_number})</span>
                  </td>
                  <td>
                    {p.purpose}
                    {p.override_reason && <Badge variant="warning" className="ms-2">override</Badge>}
                  </td>
                  <td>{fmt(p.expected_back_at)}</td>
                  <td>
                    <Badge variant={VARIANT[p.status as keyof typeof VARIANT] ?? 'outline'}>{p.status}</Badge>
                  </td>
                  <td>{(p.status === 'open' || p.status === 'overdue') && <ActionButton label="Mark returned" testId={`return-${p.serial}`} action={returnPass} args={[p.id]} />}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}

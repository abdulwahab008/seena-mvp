import Link from 'next/link';
import { headers } from 'next/headers';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { PrintButton } from '@/components/print-button';
import { gatePassUrl, qrSvg } from '@/lib/hostel/gate-pass';
import { SpecForm } from '@/components/spec-form';
import { currentRole, loose } from '@/lib/transport/rpc';
import { cancelPass } from '../actions';

export const dynamic = 'force-dynamic';

const fmt = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-GB', { timeZone: 'Asia/Karachi', dateStyle: 'medium', timeStyle: 'short' }) : '-');

// The record a gate scan opens, laid out as the printed pass: student photo box,
// GR number, serial and a QR code that resolves back to this page.
export default async function GatePassPage({ params }: { params: Promise<{ passId: string }> }) {
  const { passId } = await params;
  const supabase = loose(await supabaseServer());
  const role = await currentRole(supabase);
  const { data: pass } = await supabase
    .from('hostel_gate_pass')
    .select('id, serial, purpose, destination, departs_at, expected_back_at, returned_at, status, collector_name, collector_cnic, override_reason, student:student_id(name_en, name_ur, gr_number, photo_path), guardian:released_to_guardian_id(name_en)')
    .eq('id', passId)
    .maybeSingle();
  if (!pass) notFound();
  const student = (Array.isArray(pass.student) ? pass.student[0] : pass.student) as { name_en: string; name_ur: string | null; gr_number: string; photo_path: string | null };
  const guardian = (Array.isArray(pass.guardian) ? pass.guardian[0] : pass.guardian) as { name_en: string } | null;

  const h = await headers();
  const host = h.get('x-forwarded-host') ?? h.get('host') ?? 'localhost';
  const proto = h.get('x-forwarded-proto') ?? (host.startsWith('localhost') ? 'http' : 'https');
  const svg = await qrSvg(gatePassUrl(`${proto}://${host}`, pass.id));
  let photoUrl: string | null = null;
  if (student.photo_path) {
    const { data: signed } = await supabase.storage.from('student-photos').createSignedUrl(student.photo_path, 300);
    photoUrl = signed?.signedUrl ?? null;
  }

  return (
    <div className="mx-auto max-w-xl space-y-4 p-4 print:p-0" data-testid="gate-pass">
      <div className="flex items-center justify-between print:hidden">
        <Link href="/hostel/gate-passes" className="rounded-md border px-3 py-1.5 text-sm">
          All passes
        </Link>
        <PrintButton label="Print pass" />
      </div>
      <div className="space-y-4 rounded-lg border p-5">
        <div className="flex items-start justify-between gap-4">
          <div className="space-y-1">
            <p className="text-xs uppercase tracking-wide text-muted-foreground">Hostel gate pass</p>
            <p className="text-2xl font-semibold" data-testid="pass-serial">
              {pass.serial}
            </p>
            <Badge variant={pass.status === 'overdue' ? 'destructive' : pass.status === 'returned' ? 'success' : 'primary'} data-testid="pass-status">
              {pass.status}
            </Badge>
          </div>
          <div
            className="h-[168px] w-[168px] shrink-0"
            data-testid="pass-qr"
            // The SVG is generated here from the pass URL by the qrcode library, never from user text.
            dangerouslySetInnerHTML={{ __html: svg }}
          />
        </div>
        <div className="flex gap-4">
          {photoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={photoUrl} alt="Student" className="h-28 w-24 rounded border object-cover" data-testid="pass-photo" />
          ) : (
            <div className="flex h-28 w-24 items-center justify-center rounded border text-xs text-muted-foreground" data-testid="pass-photo-box">
              Photo
            </div>
          )}
          <dl className="grid flex-1 grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-sm">
            <dt className="text-muted-foreground">Student</dt>
            <dd className="font-medium">
              {student.name_en}
              {student.name_ur && (
                <span className="ms-2" dir="rtl">
                  {student.name_ur}
                </span>
              )}
            </dd>
            <dt className="text-muted-foreground">GR number</dt>
            <dd data-testid="pass-gr">{student.gr_number}</dd>
            <dt className="text-muted-foreground">Purpose</dt>
            <dd>{pass.purpose}</dd>
            <dt className="text-muted-foreground">Destination</dt>
            <dd>{pass.destination ?? '-'}</dd>
            <dt className="text-muted-foreground">Leaves</dt>
            <dd>{fmt(pass.departs_at)}</dd>
            <dt className="text-muted-foreground">Due back</dt>
            <dd>{fmt(pass.expected_back_at)}</dd>
            <dt className="text-muted-foreground">Returned</dt>
            <dd>{fmt(pass.returned_at)}</dd>
            <dt className="text-muted-foreground">Collected by</dt>
            <dd>
              {pass.collector_name} · {pass.collector_cnic} {guardian ? `(guardian ${guardian.name_en})` : ''}
            </dd>
          </dl>
        </div>
        {pass.override_reason && <p className="rounded-md border border-warning p-2 text-sm">Principal override: {pass.override_reason}</p>}
      </div>
      {pass.status === 'open' && !['parent', 'student'].includes(role) && (
        <div className="space-y-2 print:hidden">
          <p className="text-sm text-muted-foreground">The student has not left yet? Cancel the pass (the record is kept).</p>
          <SpecForm
            testId="cancel-pass-form"
            submitLabel="Cancel pass"
            action={cancelPass}
            columns={2}
            fields={[
              { name: 'passId', label: 'Pass', type: 'hidden', defaultValue: pass.id },
              { name: 'reason', label: 'Reason', required: true },
            ]}
          />
        </div>
      )}
    </div>
  );
}

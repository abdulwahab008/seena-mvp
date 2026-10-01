import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { formatRupees, netPayablePaisa } from '@/lib/settlements/statement';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AddLineForm, ApproveButton, ComputeButton, PaidButton, RemoveLineButton, ReviseButton } from './settlement-forms';

export const dynamic = 'force-dynamic';

export default async function SettlementPage({ params }: { params: Promise<{ exitId: string }> }) {
  const { exitId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(exitId)) notFound();
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  const allowed = ['super_admin', 'owner', 'hr_manager', 'accountant'].includes(actor?.role ?? '');
  if (!allowed) {
    return (
      <div className="space-y-2">
        <h1 className="text-2xl font-semibold">Final settlement</h1>
        <p className="text-sm text-muted-foreground">Settlement statements are visible to the Accountant, HR and the Owner.</p>
      </div>
    );
  }
  const { data: exit } = await supabase
    .from('staff_exit')
    .select('id, exit_type, last_working_date, notice_shortfall_days, status, staff:staff_id(full_name, employee_code)')
    .eq('id', exitId)
    .maybeSingle();
  if (!exit) notFound();
  const staff = one(exit.staff);

  const { data: versions } = await supabase
    .from('staff_settlement')
    .select('id, version, status, net_payable_paisa, approved_at, paid_at, superseded_at, pdf_sha256')
    .eq('exit_id', exitId)
    .order('version', { ascending: false });
  const current = (versions ?? []).find((v) => !v.superseded_at) ?? null;
  const { data: lines } = current
    ? await supabase.from('staff_settlement_line').select('id, line_type, description, amount_paisa, sign, is_manual, sort_order').eq('settlement_id', current.id).order('sort_order')
    : { data: [] };
  const rows = (lines ?? []).map((l) => ({ ...l, amountPaisa: Number(l.amount_paisa), signV: (l.sign === -1 ? -1 : 1) as 1 | -1 }));
  const net = netPayablePaisa(rows.map((r) => ({ amountPaisa: r.amountPaisa, sign: r.signV })));
  const canApprove = ['super_admin', 'owner', 'accountant'].includes(actor?.role ?? '');
  const draft = current?.status === 'draft';

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold" data-testid="settlement-heading">
            Final settlement: {staff?.full_name}
          </h1>
          <p className="text-sm text-muted-foreground">
            {staff?.employee_code} · {exit.exit_type.replace('_', ' ')} · last working date {exit.last_working_date}
            {exit.notice_shortfall_days > 0 ? ` · notice short by ${exit.notice_shortfall_days} day(s)` : ''}
          </p>
          <p className="text-sm">
            <Link className="underline" href={`/staff/exits/${exitId}`}>
              Back to the exit
            </Link>
          </p>
        </div>
        {current && <Badge variant={draft ? 'warning' : 'success'} data-testid="settlement-status">{current.status} · version {current.version}</Badge>}
      </div>

      {!current && (
        <Card>
          <CardContent className="space-y-3 p-6 text-sm">
            <p className="text-muted-foreground">No statement has been prepared. Computing it reads the salary on the contract, encashable leave, the notice shortfall and outstanding loans.</p>
            <ComputeButton exitId={exitId} label="Compute settlement" />
          </CardContent>
        </Card>
      )}

      {current && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Statement</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <table className="w-full" data-testid="settlement-lines">
              <thead>
                <tr className="border-b text-left text-muted-foreground">
                  <th className="py-2">Description</th>
                  <th className="py-2 text-right">Dues</th>
                  <th className="py-2 text-right">Deductions</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id} className="border-b" data-testid={`line-${r.line_type}`}>
                    <td className="py-2">{r.description}</td>
                    <td className="py-2 text-right tabular-nums">{r.signV === 1 ? formatRupees(r.amountPaisa) : ''}</td>
                    <td className="py-2 text-right tabular-nums">{r.signV === -1 ? formatRupees(r.amountPaisa) : ''}</td>
                    <td className="py-2 text-right">{draft && r.is_manual && <RemoveLineButton exitId={exitId} lineId={r.id} />}</td>
                  </tr>
                ))}
                <tr className="font-semibold">
                  <td className="py-2">{net >= 0 ? 'Net payable to the employee' : 'Net recoverable from the employee'}</td>
                  <td className="py-2 text-right tabular-nums" colSpan={2} data-testid="settlement-net">
                    {net < 0 ? '-' : ''}
                    {formatRupees(net)}
                  </td>
                  <td />
                </tr>
              </tbody>
            </table>

            <div className="flex flex-wrap items-start gap-3">
              {draft && <ComputeButton exitId={exitId} label="Recompute computed lines" />}
              {draft && canApprove && <ApproveButton exitId={exitId} settlementId={current.id} />}
              {current.status === 'approved' && canApprove && <PaidButton exitId={exitId} settlementId={current.id} />}
              {current.status === 'approved' && <ReviseButton exitId={exitId} settlementId={current.id} />}
              {!draft && (
                <a href={`/api/settlements/${current.id}/pdf`} className="inline-flex h-10 items-center rounded-md border px-4 text-sm font-medium" data-testid="download-settlement-pdf">
                  Download PDF
                </a>
              )}
            </div>
            {!draft && current.pdf_sha256 && <p className="text-xs text-muted-foreground" data-testid="pdf-hash">PDF sealed, SHA-256 {current.pdf_sha256}</p>}
          </CardContent>
        </Card>
      )}

      {current && draft && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add a line by hand</CardTitle>
          </CardHeader>
          <CardContent>
            <AddLineForm exitId={exitId} settlementId={current.id} />
          </CardContent>
        </Card>
      )}

      {(versions ?? []).filter((v) => v.superseded_at).length > 0 && (
        <p className="text-xs text-muted-foreground">Earlier versions on record: {(versions ?? []).filter((v) => v.superseded_at).map((v) => `v${v.version} (net ${formatRupees(Number(v.net_payable_paisa))})`).join(', ')}</p>
      )}
    </div>
  );
}

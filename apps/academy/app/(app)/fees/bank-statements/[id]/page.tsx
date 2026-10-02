import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ReconDesk, type ExceptionRow } from './recon-desk';

export default async function BankImportPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: summary } = await supabase.from('v_bank_recon_summary').select('*').eq('import_id', id).maybeSingle();
  if (!summary) notFound();

  const { data: rows } = await supabase
    .from('bank_recon_exception')
    .select('id, reason, expected_paisa, received_paisa, resolved_at, resolution_note, line:line_id(bank_ref, challan_ref, txn_date, raw_line)')
    .eq('import_id', id)
    .order('created_at');

  const exceptions: ExceptionRow[] = (rows ?? []).map((e) => {
    const line = Array.isArray(e.line) ? e.line[0] : e.line;
    return {
      id: e.id,
      reason: e.reason,
      expected: e.expected_paisa,
      received: e.received_paisa,
      resolved: Boolean(e.resolved_at),
      note: e.resolution_note,
      bankRef: line?.bank_ref ?? null,
      challanRef: line?.challan_ref ?? null,
      date: line?.txn_date ?? null,
    };
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Reconcile bank statement</h1>
        <p className="text-sm text-muted-foreground">FR-K20 — exact matches post automatically; everything else waits here for a person.</p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Status: {summary.status}</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-5" data-testid="recon-summary">
          <div>Rows: {summary.row_count}</div>
          <div>Parsed: {summary.parsed_count}</div>
          <div>Unreadable: {summary.failed_count}</div>
          <div>Matched: {summary.matched_count}</div>
          <div>Unresolved: {summary.unresolved_count}</div>
        </CardContent>
      </Card>
      <ReconDesk importId={id} status={summary.status ?? 'parsed'} unresolved={Number(summary.unresolved_count ?? 0)} exceptions={exceptions} />
    </div>
  );
}

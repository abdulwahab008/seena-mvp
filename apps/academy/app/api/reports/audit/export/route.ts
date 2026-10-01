import { NextRequest, NextResponse } from 'next/server';
import { headers } from 'next/headers';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';
import { toCsv } from '@/lib/csv';

const query = z.object({
  user: z.string().uuid().optional(),
  from: z.string().date().optional(),
  to: z.string().date().optional(),
});

// Exporting the audit list is itself audited: export_report_audit() writes the
// further audit row in the same call that returns the rows.
export async function GET(req: NextRequest) {
  const parsed = query.safeParse(Object.fromEntries(req.nextUrl.searchParams));
  if (!parsed.success) return NextResponse.json({ error: 'Invalid filter.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('export_report_audit', {
    p_user_id: parsed.data.user,
    p_from: parsed.data.from ? `${parsed.data.from}T00:00:00+05:00` : undefined,
    p_to: parsed.data.to ? `${parsed.data.to}T23:59:59.999+05:00` : undefined,
    p_ip: clientIpFromHeaders(await headers()) ?? undefined,
  });
  if (error) return NextResponse.json({ error: error.message.includes('FORBIDDEN') ? 'Only the owner can export the audit trail.' : 'Export failed.' }, { status: error.message.includes('FORBIDDEN') ? 403 : 500 });

  const csv = toCsv(
    ['executed_at', 'user_id', 'report_key', 'dataset_key', 'destination', 'row_count', 'contains_pii', 'reason', 'ip', 'filters'],
    (data ?? []).map((r) => [r.executed_at, r.user_id, r.report_key, r.dataset_key, r.destination, r.row_count, r.contains_pii, r.reason, r.ip, r.filters_json]),
  );
  return new NextResponse(csv, {
    headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="report-audit.csv"', 'cache-control': 'private, no-store' },
  });
}

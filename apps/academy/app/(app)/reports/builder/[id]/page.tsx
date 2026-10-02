import Link from 'next/link';
import { notFound } from 'next/navigation';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ReportGrid, type GridColumn, type GridRow } from '../report-grid';
import { ExportReportButtons } from '../report-actions';

// Runs a saved report as the person looking at it: SECURITY INVOKER, so a report shared by
// another campus's Principal shows this person's own campus rows, and a column their role
// may not see makes the run fail with an explanation rather than leak.

const resultSchema = z.object({
  columns: z.array(z.object({ key: z.string(), label: z.string(), type: z.string() })),
  rows: z.array(z.record(z.union([z.string(), z.number(), z.boolean(), z.null()]))),
  total_rows: z.number(),
  capped: z.boolean(),
  page: z.number(),
  page_size: z.number(),
  name: z.string(),
  notice: z.string().nullable().optional(),
  elapsed_ms: z.number().optional(),
});

export default async function SavedReportPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ page?: string }> }) {
  const { id } = await params;
  if (!z.string().uuid().safeParse(id).success) notFound();
  const page = Math.max(1, Number((await searchParams).page) || 1);
  const supabase = await supabaseServer();
  const { data: report } = await supabase.from('saved_report').select('id, name').eq('id', id).maybeSingle();
  if (!report) notFound();

  const { data, error } = await supabase.rpc('fn_run_saved_report', { saved_report_id: id, page, page_size: 100 });
  const result = error ? null : resultSchema.safeParse(data);

  return (
    <div className="space-y-6">
      <div>
        <Link href="/reports/builder" className="text-sm text-muted-foreground underline">
          Back to report builder
        </Link>
        <h1 className="mt-1 text-2xl font-semibold">{report.name}</h1>
      </div>

      {error && (
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" data-testid="run-error">
          {error.message.includes('column_not_permitted')
            ? 'Not permitted: this report includes a column your role is not allowed to see, so it cannot be run for you.'
            : 'This report could not be run.'}
        </div>
      )}

      {result?.success && (
        <>
          <p className="text-sm text-muted-foreground" data-testid="run-summary">
            Showing {result.data.rows.length} of {result.data.total_rows} rows (page {result.data.page}){result.data.elapsed_ms !== undefined ? ` · ${Math.round(result.data.elapsed_ms)} ms` : ''}
          </p>
          {result.data.notice && (
            <p role="status" className="rounded-md border border-amber-300 bg-amber-50 p-2 text-sm text-amber-900" data-testid="run-notice">
              {result.data.notice}
            </p>
          )}
          <ReportGrid columns={result.data.columns as GridColumn[]} rows={result.data.rows as GridRow[]} />
          <div className="flex gap-3 text-sm">
            {page > 1 && (
              <Link className="underline" href={`/reports/builder/${id}?page=${page - 1}`}>
                Previous page
              </Link>
            )}
            {result.data.rows.length === result.data.page_size && page * result.data.page_size < result.data.total_rows && (
              <Link className="underline" href={`/reports/builder/${id}?page=${page + 1}`} data-testid="next-page">
                Next page
              </Link>
            )}
          </div>
        </>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Export the full result</CardTitle>
        </CardHeader>
        <CardContent>
          <ExportReportButtons id={id} />
        </CardContent>
      </Card>
    </div>
  );
}

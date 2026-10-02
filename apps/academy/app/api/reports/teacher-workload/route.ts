import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { buildWorkbook } from '@/lib/xlsx/writer';
import { workloadSheet, type WorkloadRow } from '@/lib/reports/teacher-workload';

const query = z.object({ campus: z.string().uuid(), week: z.string().regex(/^\d{4}-W\d{2}$/) });

// FR-D20 (export-teacher-workload-xlsx): one header row and exactly one row per teacher. The rows come
// from get_teacher_workload(), which asserts the caller's role and campus; this handler adds nothing
// of its own to the data and no further sheets, so the workbook cannot disagree with the screen.
export async function GET(req: NextRequest) {
  const parsed = query.safeParse(Object.fromEntries(req.nextUrl.searchParams));
  if (!parsed.success) return NextResponse.json({ error: 'Choose a campus and an ISO week such as 2026-W40.' }, { status: 400 });

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('get_teacher_workload', { p_campus: parsed.data.campus, p_iso_week: parsed.data.week });
  if (error) {
    const forbidden = error.message.includes('FORBIDDEN') || error.message.includes('CAMPUS_NOT_FOUND');
    return NextResponse.json({ error: forbidden ? 'You cannot export the workload for this campus.' : 'Export failed.' }, { status: forbidden ? 403 : 500 });
  }
  const bytes = buildWorkbook([workloadSheet(parsed.data.week, (data ?? []) as WorkloadRow[])]);
  return new NextResponse(Buffer.from(bytes), {
    headers: {
      'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'content-disposition': `attachment; filename="teacher-workload-${parsed.data.week}.xlsx"`,
      'cache-control': 'private, no-store',
    },
  });
}

'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { generateCensusSchema, type GenerateCensusInput } from '@/lib/validation';
import { buildCensusFile, fillXlsxTemplate, templateValues, type CensusCell, type FrameworkSpec } from '@/lib/census/output';

export type GenerateCensusResult = { error: string | null; runId?: string; incomplete?: boolean };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only the school owner or a principal can generate a census return.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'That campus is not available to you.';
  if (message.includes('CENSUS_DATE_INVALID')) return 'The census date cannot be in the future.';
  if (message.includes('FRAMEWORK_UNKNOWN')) return 'That return format is not configured.';
  return 'Could not generate the return. Please try again.';
}

const cellsSchema = z.array(z.object({ metric: z.enum(['enrolment', 'enrolment_by_age']), dimension_key: z.record(z.string()), value: z.number() }));
const specSchema = z.object({
  framework: z.string(),
  display_name: z.string(),
  output_format: z.enum(['csv', 'xlsx']),
  cell_spec: z.object({
    gender_labels: z.record(z.string()),
    sheets: z.object({ class_gender: z.string(), age: z.string() }),
    template_map: z.array(z.object({ sheet: z.string(), ref: z.string(), metric: z.enum(['enrolment', 'enrolment_by_age', 'total']), class_code: z.string().optional(), gender: z.string().optional(), age: z.string().optional() })).nullable(),
  }),
});

// The run (and its reconciliation) is computed in the database from the roll on the census date.
// This builds the file from nothing but the stored cells, so regenerating a return reproduces it
// byte for byte.
export async function generateCensusReturn(input: GenerateCensusInput): Promise<GenerateCensusResult> {
  const p = generateCensusSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data: runId, error } = await supabase.rpc('generate_census_return', { p_campus: p.data.campusId, p_framework: p.data.framework, p_census_date: p.data.censusDate });
  if (error) return { error: mapError(error.message) };

  const [{ data: run }, { data: cellRows }, { data: specRow }, { data: classes }, { data: campus }] = await Promise.all([
    supabase.from('census_return_run').select('id, tenant_id, status, incomplete, unknown_age_count, reconciliation_ok').eq('id', runId).single(),
    supabase.from('census_cell').select('metric, dimension_key, value').eq('run_id', runId),
    supabase.from('census_framework_spec').select('framework, display_name, output_format, cell_spec').eq('framework', p.data.framework).single(),
    supabase.from('class_level').select('code, name_en, ordinal'),
    supabase.from('campus').select('name').eq('id', p.data.campusId).single(),
  ]);
  if (!run || run.status !== 'done') return { error: 'The return failed its reconciliation check and was not produced. Contact support.' };

  const cells = cellsSchema.parse(cellRows ?? []) as CensusCell[];
  const spec = specSchema.parse(specRow) as FrameworkSpec;
  const censusInput = {
    cells, spec, censusDate: p.data.censusDate, campusName: campus?.name ?? '', incomplete: run.incomplete, unknownAgeCount: run.unknown_age_count,
    classes: (classes ?? []).map((c) => ({ code: c.code, name: c.name_en, ordinal: c.ordinal })),
  };
  let file = buildCensusFile(censusInput);

  const admin = supabaseServiceRole();
  // A province that distributes a locked workbook: fill that template cell for cell instead.
  if (spec.output_format === 'xlsx' && spec.cell_spec.template_map) {
    const { data: tpl } = await admin.storage.from('census-returns').download(`${run.tenant_id}/templates/${spec.framework}.xlsx`);
    if (!tpl) return { error: 'The provincial template for this return has not been uploaded yet.' };
    const bytes = fillXlsxTemplate(new Uint8Array(await tpl.arrayBuffer()), templateValues(spec.cell_spec.template_map, cells));
    file = { ...file, bytes, sha256: (await import('node:crypto')).createHash('sha256').update(bytes).digest('hex') };
  }

  const path = `${run.tenant_id}/${p.data.campusId}/${p.data.framework}-${p.data.censusDate}-${run.id}.${file.extension}`;
  const { error: uploadError } = await admin.storage.from('census-returns').upload(path, file.bytes, { contentType: file.contentType, upsert: true });
  if (uploadError) return { error: 'The return was computed but its file could not be stored. Please try again.' };
  const { error: attachError } = await supabase.rpc('attach_census_file', { p_run_id: run.id, p_file_path: path, p_sha256: file.sha256 });
  if (attachError) return { error: 'The return was computed but its file could not be recorded. Please try again.' };

  revalidatePath('/compliance/census');
  return { error: null, runId: run.id, incomplete: run.incomplete };
}

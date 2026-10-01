import { z } from 'zod';

/** FR-D08: at most this many punches per call; the database enforces it too. */
export const MAX_PUNCHES_PER_CALL = 1000;

const punchSchema = z.object({
  code: z.union([z.string(), z.number()]).transform((v) => String(v).trim()),
  time: z.string().min(1),
  direction: z
    .string()
    .optional()
    .transform((v) => {
      const d = (v ?? '').trim().toLowerCase();
      return d === 'in' || d === 'out' ? d : 'unknown';
    }),
});

export type ParsedBatch = { ok: true; punches: { code: string; time: string; direction: 'in' | 'out' | 'unknown' }[] } | { ok: false; status: 400 | 413; error: string };

/**
 * Accepts `{ punches: [...] }` or a bare array. Entries are NOT validated
 * one by one here beyond their shape: a malformed time or empty code is
 * rejected per punch by the database so one bad row never loses the batch.
 */
export function parseBatch(rawBody: string): ParsedBatch {
  let json: unknown;
  try {
    json = JSON.parse(rawBody);
  } catch {
    return { ok: false, status: 400, error: 'Body is not valid JSON.' };
  }
  const list = Array.isArray(json) ? json : json && typeof json === 'object' ? (json as { punches?: unknown }).punches : undefined;
  if (!Array.isArray(list)) return { ok: false, status: 400, error: 'Expected a "punches" array.' };
  if (list.length > MAX_PUNCHES_PER_CALL) return { ok: false, status: 413, error: `At most ${MAX_PUNCHES_PER_CALL} punches per call.` };

  const punches: { code: string; time: string; direction: 'in' | 'out' | 'unknown' }[] = [];
  for (const item of list) {
    const r = punchSchema.safeParse(item);
    // keep an unparseable entry as an empty one so the database counts it as rejected
    punches.push(r.success ? { code: r.data.code, time: r.data.time, direction: r.data.direction as 'in' | 'out' | 'unknown' } : { code: '', time: '', direction: 'unknown' });
  }
  return { ok: true, punches };
}

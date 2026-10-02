import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

// pg_cron runs in UTC and Pakistan is UTC+5 with no DST, so each job named in the FR-D06/D08/D15/D16/D20 specs
// must be scheduled at the UTC minute that equals its stated Karachi time. pg_cron is not installed in the
// local/test database, so the migrations register the jobs conditionally and a pgTAP test cannot see them:
// pin the schedule text instead.
const dir = path.resolve(__dirname, '../supabase/migrations');
const read = (f: string) => readFileSync(path.join(dir, f), 'utf8');

function schedule(file: string, job: string): string | null {
  const m = read(file).match(new RegExp(`cron\\.schedule\\(\\s*'${job}'\\s*,\\s*'([^']+)'`));
  return m?.[1] ?? null;
}

describe('staff / HR cron jobs are scheduled in UTC for the stated PKT time', () => {
  it('FR-D06 staff-doc-expiry runs at 01:15 PKT (20:15 UTC the day before), not a naive 01:00 UTC', () => {
    expect(schedule('20260802100100_staff_document_expiry.sql', 'staff-doc-expiry')).toBe('15 20 * * *');
  });
  it('FR-D08 biometric-derive runs every 30 minutes', () => {
    expect(schedule('20260802100200_biometric_punch_ingestion.sql', 'biometric-derive')).toBe('*/30 * * * *');
  });
  it('FR-D15 showcause-overdue runs at 03:00 PKT (22:00 UTC)', () => {
    expect(schedule('20260802100300_staff_disciplinary_record.sql', 'showcause-overdue')).toBe('0 22 * * *');
  });
  it('FR-D16 contract-expiry-exit runs at 04:00 PKT (23:00 UTC)', () => {
    expect(schedule('20260802100400_staff_exit_clearance.sql', 'contract-expiry-exit')).toBe('0 23 * * *');
  });
  it('FR-D20 refresh-teacher-load runs at 02:30 PKT (21:30 UTC)', () => {
    expect(schedule('20260802100700_teacher_workload_report.sql', 'refresh-teacher-load')).toBe('30 21 * * *');
  });
});

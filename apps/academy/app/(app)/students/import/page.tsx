import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import type { Json } from '@/lib/database.types';
import { CommitImportButton, UndoImportButton } from './commit-actions';
import { ImportForm } from './import-form';

// Same roles create_import_batch() itself admits, and the same set
// import_batch_campus_scope reads back.
const IMPORT_ROLES = ['super_admin', 'owner', 'principal', 'admissions_officer'];

// undo_import_batch()'s own, narrower list: the person who can silently
// erase a day of a clerk's work is deliberately not everyone who can
// create it (the same asymmetry FR-A15 drew around restore_record).
const UNDO_ROLES = ['super_admin', 'owner', 'principal'];

// A 5,000-row file can legitimately produce thousands of issues; the page
// shows the first slice and says how many more there are rather than
// rendering a report nobody scrolls through. The downloadable failure
// report is the complete version.
const REPORT_LIMIT = 200;

type ReportIssue = { rowNo: number; column: string; message: string; severity: string };

function toIssues(rows: Array<{ row_no: number; errors: Json }>): ReportIssue[] {
  return rows.flatMap((row) =>
    (Array.isArray(row.errors) ? row.errors : []).map((entry) => {
      const issue = entry as { column?: string; message?: string; severity?: string };
      return {
        rowNo: row.row_no,
        column: issue.column ?? '',
        message: issue.message ?? '',
        severity: issue.severity ?? 'error',
      };
    }),
  );
}

export default async function StudentImportPage({ searchParams }: { searchParams: Promise<{ batch?: string }> }) {
  const { batch: batchId } = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();

  const heading = (
    <div>
      <h1 className="text-2xl font-semibold">Bulk student import</h1>
      <p className="text-sm text-muted-foreground">
        Upload your existing student register, see exactly what is wrong with it, then import the rows that are ready — all of
        them or none of them. A validation run on its own creates nothing.
      </p>
    </div>
  );

  if (!appUser || !IMPORT_ROLES.includes(appUser.app_role)) {
    return (
      <div className="space-y-6">
        {heading}
        <p className="text-sm text-muted-foreground" data-testid="import-forbidden">
          Only an Owner, Principal or Admissions Officer can import students.
        </p>
      </div>
    );
  }

  const [{ data: campuses }, { data: sessions }, { data: batches }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
    supabase
      .from('v_import_batch')
      .select(
        'id, original_filename, commit_state, can_undo, total_rows, ok_rows, warning_rows, error_rows, committed_rows, committed_at, undo_deadline, undone_at, failed_row_no, failed_message, error_report_path, created_at',
      )
      .order('created_at', { ascending: false })
      .limit(10),
  ]);

  const batch = batchId ? (batches ?? []).find((b) => b.id === batchId) ?? null : null;
  let issues: ReportIssue[] = [];
  let shownRows = 0;
  let reportUrl: string | null = null;

  if (batch) {
    const { data: rows } = await supabase
      .from('import_row')
      .select('row_no, errors')
      .eq('batch_id', batch.id!)
      .neq('severity', 'ok')
      .order('row_no')
      .limit(REPORT_LIMIT);
    issues = toIssues(rows ?? []);
    shownRows = (rows ?? []).length;

    if (batch.error_report_path) {
      const { data: signed } = await supabase.storage
        .from('import-errors')
        .createSignedUrl(batch.error_report_path, 60 * 60);
      reportUrl = signed?.signedUrl ?? null;
    }
  }

  return (
    <div className="space-y-6">
      {heading}

      <ImportForm campuses={campuses ?? []} sessions={sessions ?? []} />

      {batchId && !batch && (
        <p className="text-sm text-muted-foreground" data-testid="import-batch-missing">
          That validation run is not available.
        </p>
      )}

      {batch && (
        <div className="space-y-3" data-testid="import-report">
          <h2 className="text-lg font-medium">{batch.original_filename}</h2>
          <p className="text-sm" data-testid="import-report-summary">
            <span data-testid="import-report-ready">{batch.ok_rows}</span> ready ·{' '}
            <span data-testid="import-report-blocked">{batch.error_rows}</span> blocked ·{' '}
            <span data-testid="import-report-warnings">{batch.warning_rows}</span> with warnings, out of{' '}
            {batch.total_rows} row{batch.total_rows === 1 ? '' : 's'}.
          </p>

          <div className="space-y-3 rounded-lg border p-4" data-testid="import-commit-panel">
            <p className="text-sm" data-testid="import-commit-state">
              {batch.commit_state}
            </p>

            {batch.commit_state === 'validated' && <CommitImportButton batchId={batch.id!} okRows={batch.ok_rows!} />}

            {batch.commit_state === 'failed' && (
              <>
                <p className="text-sm text-destructive" data-testid="import-commit-failed">
                  The import stopped at row {batch.failed_row_no} and was rolled back in full — no student, no GR number and
                  no enrolment was created. {batch.failed_message}
                </p>
                <CommitImportButton batchId={batch.id!} okRows={batch.ok_rows!} />
              </>
            )}

            {batch.commit_state === 'committed' && (
              <>
                <p className="text-sm" data-testid="import-committed-summary">
                  Imported <span data-testid="import-committed-rows">{batch.committed_rows}</span> student
                  {batch.committed_rows === 1 ? '' : 's'} on {new Date(batch.committed_at!).toLocaleString()}.
                </p>
                {batch.can_undo ? (
                  <>
                    <p className="text-xs text-muted-foreground" data-testid="import-undo-deadline">
                      This import can be undone until {new Date(batch.undo_deadline!).toLocaleString()}, as long as no fee or
                      attendance record references an imported student.
                    </p>
                    {UNDO_ROLES.includes(appUser.app_role) && <UndoImportButton batchId={batch.id!} />}
                  </>
                ) : (
                  <p className="text-xs text-muted-foreground" data-testid="import-undo-closed">
                    The 24-hour window for undoing this import has closed.
                  </p>
                )}
              </>
            )}

            {batch.commit_state === 'undone' && (
              <p className="text-sm text-muted-foreground" data-testid="import-undone">
                This import was undone on {new Date(batch.undone_at!).toLocaleString()}. Upload the file again to retry.
              </p>
            )}

            {reportUrl && (
              <a href={reportUrl} className="block text-sm underline" download data-testid="import-failure-report-link">
                Download the failure report ({batch.error_rows} blocked row{batch.error_rows === 1 ? '' : 's'})
              </a>
            )}
          </div>

          {issues.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="import-report-clean">
              Every row is ready to import.
            </p>
          ) : (
            <table className="w-full text-left text-sm" data-testid="import-report-table">
              <thead className="text-xs uppercase text-muted-foreground">
                <tr>
                  <th className="py-2 pr-4 font-medium">Row</th>
                  <th className="py-2 pr-4 font-medium">Column</th>
                  <th className="py-2 pr-4 font-medium">Problem</th>
                  <th className="py-2 font-medium">Severity</th>
                </tr>
              </thead>
              <tbody>
                {issues.map((issue, i) => (
                  <tr key={`${issue.rowNo}-${issue.column}-${i}`} className="border-t align-top" data-testid={`import-issue-${issue.rowNo}-${issue.column}`}>
                    <td className="py-2 pr-4 tabular-nums">{issue.rowNo}</td>
                    <td className="py-2 pr-4 font-mono text-xs">{issue.column}</td>
                    <td className="py-2 pr-4">{issue.message}</td>
                    <td className="py-2 text-xs uppercase">{issue.severity === 'warning' ? 'Warning' : 'Blocked'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          {shownRows === REPORT_LIMIT && batch.error_rows! + batch.warning_rows! > REPORT_LIMIT && (
            <p className="text-xs text-muted-foreground" data-testid="import-report-truncated">
              Showing the first {REPORT_LIMIT} affected rows of {batch.error_rows! + batch.warning_rows!}.
            </p>
          )}
        </div>
      )}

      <div className="space-y-2">
        <h2 className="text-lg font-medium">Recent import runs</h2>
        {(batches ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No file has been validated yet.</p>
        ) : (
          <ul className="space-y-1 text-sm">
            {(batches ?? []).map((b) => (
              <li key={b.id} data-testid={`import-batch-${b.id}`}>
                <Link href={`/students/import?batch=${b.id}`} className="underline">
                  {b.original_filename}
                </Link>{' '}
                <span className="text-muted-foreground">
                  — {b.ok_rows} ready, {b.error_rows} blocked, {b.commit_state} ({new Date(b.created_at!).toLocaleString()})
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

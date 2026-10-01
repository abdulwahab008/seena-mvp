'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { checkExport, findStudents, generateExport, saveFeeSchedule, saveRegistration, type StudentMatch } from './actions';
import {
  CATEGORY_LABEL,
  reconciliationHeadline,
  sortErrors,
  type ExportReadiness,
  type Reconciliation,
} from '@/lib/board-exam-form';
import { formatPkr } from '@/lib/challan/html';
import { BOARD_CODES, CANDIDATE_CATEGORIES, REGISTRATION_ELECTIONS } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

type ScheduleRow = { id: string; label: string; perCandidate: string; perPaper: string; window: string };
type RegistrationRow = { id: string; name: string; gr: string; board: string; year: number; category: string; roll: string | null; computed: string; collected: string; status: string };
type Props = { campusId: string; sessionId: string; schedule: ScheduleRow[]; registrations: RegistrationRow[] };

const input = 'h-9 rounded-md border bg-background px-2 text-sm';
const thisYear = new Date().getFullYear();

export function BoardFormsBoard({ campusId, sessionId, schedule, registrations }: Props) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);

  // fee schedule
  const [fee, setFee] = useState({ boardCode: 'FBISE', sessionYear: String(thisYear), category: 'regular', perCandidate: '', perPaper: '', effectiveFrom: '', note: '' });
  // registration
  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<StudentMatch[]>([]);
  const [student, setStudent] = useState<StudentMatch | null>(null);
  const [reg, setReg] = useState({ boardCode: 'FBISE', sessionYear: String(thisYear), sessionDate: '', category: 'regular', group: '', roll: '' });
  const [subjects, setSubjects] = useState<{ code: string; election: (typeof REGISTRATION_ELECTIONS)[number] }[]>([{ code: '', election: 'compulsory' }]);
  // export
  const [ex, setEx] = useState({ boardCode: 'FBISE', sessionYear: String(thisYear) });
  const [exportId, setExportId] = useState<string | null>(null);
  const [readiness, setReadiness] = useState<ExportReadiness | null>(null);
  const [rec, setRec] = useState<Reconciliation | null>(null);
  const [download, setDownload] = useState<string | null>(null);

  const run = async (fn: () => Promise<{ error: string | null; message?: string }>, after?: () => void) => {
    setBusy(true);
    const r = await fn();
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    toast.success(r.message ?? 'Done.');
    after?.();
    router.refresh();
  };

  const exportInput = { campusId, sessionId, boardCode: ex.boardCode, sessionYear: Number(ex.sessionYear) };

  const onCheck = async () => {
    setBusy(true);
    setDownload(null);
    const r = await checkExport(exportInput);
    setBusy(false);
    if (r.error) return void toast.error(r.error);
    setExportId(r.exportId ?? null);
    setReadiness(r.readiness ?? null);
    setRec(r.reconciliation ?? null);
  };

  const onGenerate = async () => {
    if (!exportId) return;
    setBusy(true);
    const r = await generateExport(exportInput, exportId);
    setBusy(false);
    if (r.error) {
      toast.error(r.error);
      if (r.readiness) setReadiness(r.readiness);
      return;
    }
    setReadiness(r.readiness ?? null);
    setRec(r.reconciliation ?? null);
    setDownload(r.downloadUrl ?? null);
    toast.success(`${r.rowCount} candidates exported.`);
  };

  return (
    <div className="space-y-10">
      <section className="space-y-3" data-testid="fee-schedule">
        <h2 className="text-lg font-semibold">Board fee schedule</h2>
        <p className="text-xs text-muted-foreground">
          Effective-dated. A revision closes the version it replaces the day before it takes effect, and an export prices
          each candidate on the version in force on their session date.
        </p>
        <div className="flex flex-wrap items-end gap-3 text-sm">
          <label className="space-y-1">
            <span className="block text-muted-foreground">Board</span>
            <select className={input} value={fee.boardCode} data-testid="fee-board" onChange={(e) => setFee({ ...fee, boardCode: e.target.value })}>
              {BOARD_CODES.map((b) => (
                <option key={b}>{b}</option>
              ))}
            </select>
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Session year</span>
            <input className={`${input} w-24`} value={fee.sessionYear} data-testid="fee-year" onChange={(e) => setFee({ ...fee, sessionYear: e.target.value })} />
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Category</span>
            <select className={input} value={fee.category} data-testid="fee-category" onChange={(e) => setFee({ ...fee, category: e.target.value })}>
              {CANDIDATE_CATEGORIES.map((c) => (
                <option key={c} value={c}>
                  {CATEGORY_LABEL[c]}
                </option>
              ))}
            </select>
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Per candidate (PKR)</span>
            <input className={`${input} w-28`} inputMode="decimal" value={fee.perCandidate} data-testid="fee-per-candidate" onChange={(e) => setFee({ ...fee, perCandidate: e.target.value })} />
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Per paper (PKR)</span>
            <input className={`${input} w-28`} inputMode="decimal" value={fee.perPaper} data-testid="fee-per-paper" onChange={(e) => setFee({ ...fee, perPaper: e.target.value })} />
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Effective from</span>
            <input type="date" className={input} value={fee.effectiveFrom} data-testid="fee-effective" onChange={(e) => setFee({ ...fee, effectiveFrom: e.target.value })} />
          </label>
          <Button
            disabled={busy}
            data-testid="fee-save"
            onClick={() =>
              void run(() =>
                saveFeeSchedule({
                  boardCode: fee.boardCode,
                  sessionYear: Number(fee.sessionYear),
                  candidateCategory: fee.category,
                  perCandidateRupees: Number(fee.perCandidate || 0),
                  perPaperRupees: Number(fee.perPaper || 0),
                  effectiveFrom: fee.effectiveFrom,
                  note: fee.note,
                }),
              )
            }
          >
            Save schedule
          </Button>
        </div>
        {schedule.length > 0 && (
          <table className="w-full text-sm" data-testid="fee-table">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Board · year · category</th>
                <th className="py-1">Per candidate</th>
                <th className="py-1">Per paper</th>
                <th className="py-1">In force</th>
              </tr>
            </thead>
            <tbody>
              {schedule.map((s) => (
                <tr key={s.id} className="border-t">
                  <td className="py-1">{s.label}</td>
                  <td className="py-1">{s.perCandidate}</td>
                  <td className="py-1">{s.perPaper}</td>
                  <td className="py-1">{s.window}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="space-y-3" data-testid="registration">
        <h2 className="text-lg font-semibold">Register a candidate</h2>
        <div className="flex flex-wrap items-end gap-3 text-sm">
          <label className="space-y-1">
            <span className="block text-muted-foreground">Student (name or GR)</span>
            <input
              className={`${input} w-56`}
              value={student ? `${student.name} · ${student.gr}` : query}
              data-testid="reg-student-search"
              onChange={async (e) => {
                setStudent(null);
                setQuery(e.target.value);
                setMatches(await findStudents(e.target.value));
              }}
            />
          </label>
          {!student && matches.length > 0 && (
            <ul className="space-y-1 text-sm" data-testid="reg-matches">
              {matches.map((m) => (
                <li key={m.id}>
                  <button type="button" className="underline" data-testid={`reg-pick-${m.gr}`} onClick={() => setStudent(m)}>
                    {m.name} · {m.gr}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        <div className="flex flex-wrap items-end gap-3 text-sm">
          <label className="space-y-1">
            <span className="block text-muted-foreground">Board</span>
            <select className={input} value={reg.boardCode} data-testid="reg-board" onChange={(e) => setReg({ ...reg, boardCode: e.target.value })}>
              {BOARD_CODES.map((b) => (
                <option key={b}>{b}</option>
              ))}
            </select>
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Session year</span>
            <input className={`${input} w-24`} value={reg.sessionYear} data-testid="reg-year" onChange={(e) => setReg({ ...reg, sessionYear: e.target.value })} />
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Exam session date</span>
            <input type="date" className={input} value={reg.sessionDate} data-testid="reg-date" onChange={(e) => setReg({ ...reg, sessionDate: e.target.value })} />
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Category</span>
            <select className={input} value={reg.category} data-testid="reg-category" onChange={(e) => setReg({ ...reg, category: e.target.value })}>
              {CANDIDATE_CATEGORIES.map((c) => (
                <option key={c} value={c}>
                  {CATEGORY_LABEL[c]}
                </option>
              ))}
            </select>
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Group</span>
            <input className={`${input} w-28`} placeholder="PRE_ENG" value={reg.group} data-testid="reg-group" onChange={(e) => setReg({ ...reg, group: e.target.value })} />
          </label>
          <label className="space-y-1">
            <span className="block text-muted-foreground">Board roll no.</span>
            <input className={`${input} w-28`} value={reg.roll} data-testid="reg-roll" onChange={(e) => setReg({ ...reg, roll: e.target.value })} />
          </label>
        </div>
        <div className="space-y-2">
          <p className="text-sm text-muted-foreground">Subjects (board subject code and election)</p>
          {subjects.map((s, i) => (
            <div key={i} className="flex gap-2">
              <input
                className={`${input} w-24`}
                placeholder="PHY"
                value={s.code}
                data-testid={`reg-subject-code-${i}`}
                onChange={(e) => setSubjects(subjects.map((x, j) => (j === i ? { ...x, code: e.target.value } : x)))}
              />
              <select
                className={input}
                value={s.election}
                data-testid={`reg-subject-election-${i}`}
                onChange={(e) => setSubjects(subjects.map((x, j) => (j === i ? { ...x, election: e.target.value as (typeof REGISTRATION_ELECTIONS)[number] } : x)))}
              >
                {REGISTRATION_ELECTIONS.map((el) => (
                  <option key={el}>{el}</option>
                ))}
              </select>
            </div>
          ))}
          <div className="flex gap-2">
            <Button variant="outline" size="sm" data-testid="reg-add-subject" onClick={() => setSubjects([...subjects, { code: '', election: reg.category === 'improvement' ? 'improvement' : 'compulsory' }])}>
              Add subject
            </Button>
            <Button
              size="sm"
              disabled={busy}
              data-testid="reg-save"
              onClick={() =>
                void run(() =>
                  saveRegistration({
                    studentId: student?.id ?? '',
                    sessionId,
                    boardCode: reg.boardCode,
                    sessionYear: Number(reg.sessionYear),
                    sessionDate: reg.sessionDate,
                    candidateCategory: reg.category,
                    groupCode: reg.group,
                    rollNo: reg.roll,
                    subjects: subjects.filter((s) => s.code.trim() !== '').map((s) => ({ subjectCode: s.code, election: s.election })),
                  }),
                )
              }
            >
              Save registration
            </Button>
          </div>
        </div>
        {registrations.length > 0 && (
          <table className="w-full text-sm" data-testid="registration-table">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Candidate</th>
                <th className="py-1">Board</th>
                <th className="py-1">Category</th>
                <th className="py-1">Board fee</th>
                <th className="py-1">Collected</th>
                <th className="py-1">Status</th>
              </tr>
            </thead>
            <tbody>
              {registrations.map((r) => (
                <tr key={r.id} className="border-t" data-testid={`registration-${r.gr}`}>
                  <td className="py-1">
                    {r.name}
                    <span className="block text-xs text-muted-foreground">{r.gr}</span>
                  </td>
                  <td className="py-1">
                    {r.board} {r.year}
                  </td>
                  <td className="py-1">{CATEGORY_LABEL[r.category] ?? r.category}</td>
                  <td className="py-1">{r.computed}</td>
                  <td className="py-1">{r.collected}</td>
                  <td className="py-1">{r.status.replace('_', ' ')}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="space-y-4" data-testid="export-section">
        <h2 className="text-lg font-semibold">Export and reconcile</h2>
        <div className="flex flex-wrap items-end gap-3 text-sm">
          <div className="space-y-1">
            <Label htmlFor="ex-board">Board</Label>
            <select id="ex-board" className={input} value={ex.boardCode} data-testid="ex-board" onChange={(e) => setEx({ ...ex, boardCode: e.target.value })}>
              {BOARD_CODES.map((b) => (
                <option key={b}>{b}</option>
              ))}
            </select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="ex-year">Session year</Label>
            <input id="ex-year" className={`${input} w-24`} value={ex.sessionYear} data-testid="ex-year" onChange={(e) => setEx({ ...ex, sessionYear: e.target.value })} />
          </div>
          <Button variant="outline" disabled={busy} data-testid="ex-check" onClick={() => void onCheck()}>
            Check and reconcile
          </Button>
        </div>

        {rec && (
          <div className="space-y-3 rounded-md border p-4" data-testid="reconciliation">
            <p className="font-medium" data-testid="reconciliation-headline">
              {reconciliationHeadline(rec)}
            </p>
            <p className="text-xs text-muted-foreground">
              {rec.candidates} candidates ·{' '}
              {Object.entries(rec.by_category)
                .map(([c, v]) => `${v.candidates} ${CATEGORY_LABEL[c]?.toLowerCase() ?? c} (${formatPkr(v.computed_paisa)})`)
                .join(' · ')}
            </p>
            {rec.unpaid.length > 0 && (
              <div data-testid="unpaid-list">
                <p className="text-sm font-medium">Paid nothing ({rec.unpaid.length})</p>
                <ul className="text-sm text-muted-foreground">
                  {rec.unpaid.map((u) => (
                    <li key={u.registration_id} data-testid={`unpaid-${u.gr_number}`}>
                      {u.student_name} · {u.gr_number} · owes {formatPkr(u.owed_paisa ?? 0)}
                    </li>
                  ))}
                </ul>
              </div>
            )}
            {rec.short.length > 0 && (
              <div data-testid="short-list">
                <p className="text-sm font-medium">Paid part ({rec.short.length})</p>
                <ul className="text-sm text-muted-foreground">
                  {rec.short.map((u) => (
                    <li key={u.registration_id}>
                      {u.student_name} · {u.gr_number} · still owes {formatPkr(u.owed_paisa ?? 0)}
                    </li>
                  ))}
                </ul>
              </div>
            )}
            {rec.billing_mismatch.length > 0 && (
              <div data-testid="mismatch-list">
                <p className="text-sm font-medium text-destructive">Billed differently from the board&rsquo;s fee ({rec.billing_mismatch.length})</p>
                <ul className="text-sm text-muted-foreground">
                  {rec.billing_mismatch.map((u) => (
                    <li key={u.registration_id}>
                      {u.student_name} · billed {formatPkr(u.billed_paisa ?? 0)} for {formatPkr(u.computed_paisa ?? 0)}
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </div>
        )}

        {readiness && (
          <div className="space-y-3" data-testid="readiness">
            <p className="text-sm">
              <span data-testid="blocking-count">{readiness.blocking_count}</span> blocking ·{' '}
              <span data-testid="warning-count">{readiness.warning_count}</span> warnings
            </p>
            {readiness.errors.length > 0 && (
              <ul className="space-y-1 text-sm" data-testid="error-list">
                {sortErrors(readiness.errors).map((e, i) => (
                  <li key={`${e.registration_id}-${e.rule_code}-${i}`} className={e.severity === 'blocking' ? 'text-destructive' : 'text-muted-foreground'} data-testid={`error-${e.gr_number}-${e.rule_code}`}>
                    {e.student_name} ({e.gr_number}) — {e.message}
                    {e.subject_code && <strong className="ml-1">{e.subject_code}</strong>}
                  </li>
                ))}
              </ul>
            )}
            <Button disabled={busy || !readiness.can_generate} data-testid="ex-generate" onClick={() => void onGenerate()}>
              Generate file
            </Button>
            {download && (
              <p className="text-sm" data-testid="ex-download">
                <a href={download} className="underline">
                  Download the board examination form (CSV)
                </a>
              </p>
            )}
          </div>
        )}
      </section>
    </div>
  );
}

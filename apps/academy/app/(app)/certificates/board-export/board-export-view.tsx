'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { checkBoardExport, generateBoardExport, normaliseBoardExport, type GenerateState } from './actions';
import { boardExportFieldLabel, type BoardExportRowError } from '@/lib/board-export';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type CampusOption = { id: string; code: string; name: string };
export type SessionOption = { id: string; name: string };
export type ClassLevelOption = { id: string; code: string; name_en: string };
export type PastRun = {
  id: string;
  board_code: string;
  class_level_id: string;
  status: string;
  row_count: number | null;
  checksum: string | null;
  file_path: string | null;
  generated_at: string | null;
  requested_at: string;
};

const NO_BOARD = '__auto__';

export function BoardExportView({
  campuses,
  sessions,
  classLevels,
  boards,
  runs,
  studentNames,
}: {
  campuses: CampusOption[];
  sessions: SessionOption[];
  classLevels: ClassLevelOption[];
  boards: string[];
  runs: PastRun[];
  studentNames: Record<string, string>;
}) {
  const [pending, startTransition] = useTransition();
  const [campusId, setCampusId] = useState(campuses[0]?.id ?? '');
  const [sessionId, setSessionId] = useState(sessions[0]?.id ?? '');
  const [classLevelId, setClassLevelId] = useState(classLevels[0]?.id ?? '');
  const [board, setBoard] = useState(NO_BOARD);
  const [state, setState] = useState<GenerateState>({ error: null });

  const readiness = state.readiness ?? {};
  const blocking = Number(readiness.blocking_count ?? 0);
  const warnings = Number(readiness.warning_count ?? 0);
  const normalisable = Number(readiness.normalisable_count ?? 0);
  const studentCount = Number(readiness.student_count ?? 0);
  const errors: BoardExportRowError[] = state.errors ?? [];
  const nameOf = (id: string) => studentNames[id] ?? id.slice(0, 8);
  const classCode = (id: string) => classLevels.find((c) => c.id === id)?.name_en ?? id.slice(0, 8);

  const run = (action: typeof checkBoardExport, fd: FormData, onOk?: (s: GenerateState) => void) => {
    startTransition(async () => {
      const result = (await action({ error: null }, fd)) as GenerateState;
      setState(result);
      if (result.error) toast.error(result.error);
      else onOk?.(result);
    });
  };

  const onCheck = () => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('classLevelId', classLevelId);
    if (board !== NO_BOARD) fd.set('board', board);
    run(checkBoardExport, fd, (r) => {
      const b = Number((r.readiness ?? {}).blocking_count ?? 0);
      toast.success(b === 0 ? 'Every row is ready for the board.' : `${b} blocking problem${b === 1 ? '' : 's'} to fix.`);
    });
  };

  const onNormalise = () => {
    const fd = new FormData();
    fd.set('runId', state.runId ?? '');
    run(normaliseBoardExport, fd, () => toast.success('Identity numbers reformatted for this board.'));
  };

  const onGenerate = () => {
    const fd = new FormData();
    fd.set('runId', state.runId ?? '');
    startTransition(async () => {
      const result = await generateBoardExport({ error: null }, fd);
      setState(result);
      if (result.error) toast.error(result.error);
      else toast.success(`File ready — ${result.rowCount ?? 0} candidates.`);
    });
  };

  return (
    <div className="space-y-6">
      <div className="space-y-4 rounded-lg border p-4">
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor="board-export-campus">Campus</Label>
            <Select value={campusId} onValueChange={setCampusId}>
              <SelectTrigger id="board-export-campus" data-testid="board-export-campus-trigger">
                <SelectValue placeholder="Campus" />
              </SelectTrigger>
              <SelectContent>
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id} data-testid={`board-export-campus-option-${c.code}`}>
                    {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="board-export-session">Session</Label>
            <Select value={sessionId} onValueChange={setSessionId}>
              <SelectTrigger id="board-export-session" data-testid="board-export-session-trigger">
                <SelectValue placeholder="Session" />
              </SelectTrigger>
              <SelectContent>
                {sessions.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="board-export-class">Class level</Label>
            <Select value={classLevelId} onValueChange={setClassLevelId}>
              <SelectTrigger id="board-export-class" data-testid="board-export-class-trigger">
                <SelectValue placeholder="Class level" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.id} data-testid={`board-export-class-option-${c.code}`}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="board-export-board">Board</Label>
            <Select value={board} onValueChange={setBoard}>
              <SelectTrigger id="board-export-board" data-testid="board-export-board-trigger">
                <SelectValue placeholder="From the section" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={NO_BOARD} data-testid="board-export-board-option-auto">
                  From the section
                </SelectItem>
                {boards.map((b) => (
                  <SelectItem key={b} value={b} data-testid={`board-export-board-option-${b}`}>
                    {b.replace('_', '-')}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <Button type="button" disabled={pending} onClick={onCheck} data-testid="board-export-check-button">
            {pending ? 'Checking…' : 'Check data'}
          </Button>
        </div>
      </div>

      {state.runId && (
        <div className="space-y-4 rounded-lg border p-4" data-testid="board-export-readiness">
          <div className="flex flex-wrap items-center gap-4 text-sm">
            <span data-testid="board-export-student-count">
              <strong>{studentCount}</strong> candidate{studentCount === 1 ? '' : 's'}
            </span>
            <span data-testid="board-export-blocking-count">
              <strong>{blocking}</strong> blocking
            </span>
            <span data-testid="board-export-warning-count">
              <strong>{warnings}</strong> warning{warnings === 1 ? '' : 's'}
            </span>
            <span className="text-muted-foreground">{String(readiness.board_code ?? '')}</span>
          </div>

          <div className="flex flex-wrap gap-2">
            {normalisable > 0 && (
              <Button type="button" variant="secondary" disabled={pending} onClick={onNormalise} data-testid="board-export-normalise-button">
                Normalise {normalisable} identity number{normalisable === 1 ? '' : 's'}
              </Button>
            )}
            {/* A completed run is terminal (AC4): the way to regenerate is
                Check data again, which starts a new run and leaves this
                file downloadable. */}
            {!state.downloadUrl && (
              <Button type="button" disabled={pending || blocking > 0} onClick={onGenerate} data-testid="board-export-generate-button">
                {pending ? 'Generating…' : 'Generate file'}
              </Button>
            )}
          </div>

          {blocking > 0 && (
            <p className="text-sm text-muted-foreground" data-testid="board-export-blocked-note">
              The board rejects the whole file for one bad row, so the file is not produced while anything above is blocking.
            </p>
          )}

          {errors.length > 0 ? (
            <div className="overflow-x-auto">
              <table className="w-full text-sm" data-testid="board-export-error-table">
                <thead>
                  <tr className="border-b text-left">
                    <th className="p-2">Candidate</th>
                    <th className="p-2">Field</th>
                    <th className="p-2">Current value</th>
                    <th className="p-2">Expected</th>
                    <th className="p-2">Severity</th>
                  </tr>
                </thead>
                <tbody>
                  {errors.map((e, i) => (
                    <tr key={`${e.student_id}-${e.rule_code}-${i}`} className="border-b" data-testid={`board-export-error-${e.rule_code}`}>
                      <td className="p-2">{nameOf(e.student_id)}</td>
                      <td className="p-2">{boardExportFieldLabel(e.field_path)}</td>
                      <td className="p-2 font-mono text-xs">{e.current_value ?? '—'}</td>
                      <td className="p-2">{e.expected ?? '—'}</td>
                      <td className="p-2">{e.severity}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="text-sm text-muted-foreground" data-testid="board-export-all-clear">
              Every candidate passes this board&apos;s rules.
            </p>
          )}

          {state.downloadUrl && (
            <p className="text-sm" data-testid="board-export-latest-result">
              {state.rowCount} candidate{state.rowCount === 1 ? '' : 's'} —{' '}
              <a href={state.downloadUrl} className="underline" data-testid="board-export-download-link" download>
                Download
              </a>
            </p>
          )}
        </div>
      )}

      <div className="space-y-2">
        <h2 className="text-lg font-medium">Previous exports</h2>
        {runs.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="board-export-no-runs">
            No board file has been generated yet.
          </p>
        ) : (
          runs.map((r) => (
            <Card key={r.id} data-testid={`board-export-run-${r.id}`}>
              <CardContent className="p-4 text-sm">
                <p className="font-medium">
                  {r.board_code.replace('_', '-')} · {classCode(r.class_level_id)} · {r.status}
                  {r.row_count !== null ? ` · ${r.row_count} candidates` : ''}
                </p>
                <p className="text-xs text-muted-foreground">
                  {r.generated_at ? `Generated ${new Date(r.generated_at).toLocaleString()}` : `Started ${new Date(r.requested_at).toLocaleString()}`}
                  {r.checksum ? ` · sha256 ${r.checksum.slice(0, 12)}…` : ''}
                </p>
              </CardContent>
            </Card>
          ))
        )}
      </div>
    </div>
  );
}

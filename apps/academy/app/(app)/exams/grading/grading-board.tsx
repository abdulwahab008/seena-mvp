'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { activateGradingScheme, newGradingSchemeVersion, saveGradingScheme } from './actions';
import {
  BOARDS,
  FBISE_PRESET_BANDS,
  gradingBandCoverageError,
  type Board,
  type GradingBandInput,
  type GradingSchemeStatus,
} from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

/** One row of v_grading_scheme. */
export type GradingSchemeRow = {
  id: string;
  board: Board;
  name: string;
  effective_from: string;
  version: number;
  status: GradingSchemeStatus;
  band_count: number;
  bands: unknown;
  coverage_error: string | null;
};

type StoredBand = {
  grade_label: string;
  min_pct: number;
  max_pct: number;
  gpa_point: number | null;
  is_pass: boolean;
  remark_en: string | null;
  remark_ur: string | null;
};

const readBands = (raw: unknown): StoredBand[] => (Array.isArray(raw) ? (raw as StoredBand[]) : []);

const toEditable = (bands: StoredBand[]): GradingBandInput[] =>
  bands.map((b) => ({
    gradeLabel: b.grade_label,
    minPct: Number(b.min_pct),
    maxPct: Number(b.max_pct),
    gpaPoint: b.gpa_point === null ? null : Number(b.gpa_point),
    isPass: b.is_pass,
    remarkEn: b.remark_en ?? undefined,
    remarkUr: b.remark_ur ?? undefined,
  }));

const blankBand = (): GradingBandInput => ({
  gradeLabel: '',
  minPct: 0,
  maxPct: 0,
  gpaPoint: null,
  isPass: true,
  remarkEn: undefined,
  remarkUr: undefined,
});

const today = () => new Date().toISOString().slice(0, 10);

/**
 * FR-J01's configuration screen.
 *
 * The coverage rule is checked here as you type AND again in the database
 * before a single row is written — lib/validation.ts holds the same rule
 * app.fn_grading_band_coverage_error() does. That is duplication with a
 * purpose: a boundary is far easier to fix while you can still see the band
 * that leaves the gap, and the database stays the gate either way.
 */
export function GradingSchemeBoard({ schemes, canEdit }: { schemes: GradingSchemeRow[]; canEdit: boolean }) {
  const router = useRouter();
  const [editing, setEditing] = useState<{ schemeId?: string; board: Board; name: string; effectiveFrom: string } | null>(
    null,
  );
  const [bands, setBands] = useState<GradingBandInput[]>([]);
  const [busy, setBusy] = useState('');
  const [versionDates, setVersionDates] = useState<Record<string, string>>({});

  const coverageError = editing ? gradingBandCoverageError(bands) : null;

  const openNew = () => {
    setEditing({ board: 'FBISE', name: '', effectiveFrom: today() });
    setBands([]);
  };

  const openDraft = (scheme: GradingSchemeRow) => {
    setEditing({
      schemeId: scheme.id,
      board: scheme.board,
      name: scheme.name,
      effectiveFrom: scheme.effective_from,
    });
    setBands(toEditable(readBands(scheme.bands)));
  };

  const patchBand = (index: number, patch: Partial<GradingBandInput>) =>
    setBands((prev) => prev.map((b, i) => (i === index ? { ...b, ...patch } : b)));

  const onSave = async () => {
    if (!editing) return;
    setBusy('save');
    const result = await saveGradingScheme({ ...editing, bands });
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success('Scheme saved as a draft. Activate it to start grading on it.');
    setEditing(null);
    router.refresh();
  };

  const onActivate = async (schemeId: string) => {
    setBusy(schemeId);
    const result = await activateGradingScheme({ schemeId });
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success('Activated. Its bands are frozen from here.');
    router.refresh();
  };

  const onNewVersion = async (schemeId: string) => {
    setBusy(schemeId);
    const result = await newGradingSchemeVersion({
      schemeId,
      effectiveFrom: versionDates[schemeId] ?? today(),
    });
    setBusy('');
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success('A new draft version was created. Results already computed keep the old one.');
    router.refresh();
  };

  return (
    <div className="space-y-6" data-testid="grading-board">
      {canEdit && !editing && (
        <Button data-testid="grading-new-scheme" onClick={openNew}>
          New grading scheme
        </Button>
      )}

      {editing && (
        <section className="space-y-4 rounded-lg border p-4" data-testid="grading-editor">
          <div className="flex flex-wrap items-end gap-3">
            <div className="space-y-1">
              <Label htmlFor="grading-board-select">Board</Label>
              <select
                id="grading-board-select"
                className="h-9 rounded-md border bg-background px-3 text-sm"
                data-testid="grading-board-select"
                value={editing.board}
                onChange={(e) => setEditing({ ...editing, board: e.target.value as Board })}
              >
                {BOARDS.map((b) => (
                  <option key={b} value={b}>
                    {b}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <Label htmlFor="grading-name">Name</Label>
              <Input
                id="grading-name"
                data-testid="grading-name"
                placeholder="FBISE 2025"
                value={editing.name}
                onChange={(e) => setEditing({ ...editing, name: e.target.value })}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="grading-effective-from">Effective from</Label>
              <Input
                id="grading-effective-from"
                type="date"
                data-testid="grading-effective-from"
                value={editing.effectiveFrom}
                onChange={(e) => setEditing({ ...editing, effectiveFrom: e.target.value })}
              />
            </div>
            <Button
              variant="outline"
              data-testid="grading-preset-fbise"
              onClick={() => setBands(FBISE_PRESET_BANDS.map((b) => ({ ...b })))}
            >
              Load published FBISE scale
            </Button>
          </div>

          <div className="space-y-2">
            {bands.length === 0 && (
              <p className="text-sm text-muted-foreground">
                No bands yet. Load the FBISE preset or add them one at a time.
              </p>
            )}
            {bands.map((band, i) => (
              <div key={i} className="flex flex-wrap items-end gap-2" data-testid={`grading-band-row-${i}`}>
                <div className="space-y-1">
                  <Label htmlFor={`grading-band-label-${i}`}>Grade</Label>
                  <Input
                    id={`grading-band-label-${i}`}
                    data-testid={`grading-band-label-${i}`}
                    className="w-20"
                    value={band.gradeLabel}
                    onChange={(e) => patchBand(i, { gradeLabel: e.target.value })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor={`grading-band-min-${i}`}>From %</Label>
                  <Input
                    id={`grading-band-min-${i}`}
                    data-testid={`grading-band-min-${i}`}
                    className="w-24"
                    type="number"
                    step="0.01"
                    value={band.minPct}
                    onChange={(e) => patchBand(i, { minPct: Number(e.target.value) })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor={`grading-band-max-${i}`}>To %</Label>
                  <Input
                    id={`grading-band-max-${i}`}
                    data-testid={`grading-band-max-${i}`}
                    className="w-24"
                    type="number"
                    step="0.01"
                    value={band.maxPct}
                    onChange={(e) => patchBand(i, { maxPct: Number(e.target.value) })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor={`grading-band-gpa-${i}`}>GPA</Label>
                  <Input
                    id={`grading-band-gpa-${i}`}
                    data-testid={`grading-band-gpa-${i}`}
                    className="w-24"
                    type="number"
                    step="0.01"
                    placeholder="ungraded"
                    value={band.gpaPoint ?? ''}
                    onChange={(e) => patchBand(i, { gpaPoint: e.target.value === '' ? null : Number(e.target.value) })}
                  />
                </div>
                <div className="space-y-1">
                  <Label htmlFor={`grading-band-remark-${i}`}>Remark</Label>
                  <Input
                    id={`grading-band-remark-${i}`}
                    data-testid={`grading-band-remark-${i}`}
                    className="w-40"
                    value={band.remarkEn ?? ''}
                    onChange={(e) => patchBand(i, { remarkEn: e.target.value || undefined })}
                  />
                </div>
                <label className="flex h-9 items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    data-testid={`grading-band-pass-${i}`}
                    checked={band.isPass}
                    onChange={(e) => patchBand(i, { isPass: e.target.checked })}
                  />
                  Pass
                </label>
                <Button
                  variant="outline"
                  data-testid={`grading-band-remove-${i}`}
                  onClick={() => setBands((prev) => prev.filter((_, j) => j !== i))}
                >
                  Remove
                </Button>
              </div>
            ))}
            <Button variant="outline" data-testid="grading-band-add" onClick={() => setBands((prev) => [...prev, blankBand()])}>
              Add band
            </Button>
          </div>

          {coverageError ? (
            <p className="text-sm text-destructive" data-testid="grading-coverage-error">
              {coverageError}
            </p>
          ) : (
            <p className="text-sm text-muted-foreground" data-testid="grading-coverage-ok">
              These bands cover 0.00% to 100.00% exactly once.
            </p>
          )}

          <div className="flex gap-2">
            <Button disabled={busy === 'save' || coverageError !== null} data-testid="grading-save" onClick={() => void onSave()}>
              {busy === 'save' ? 'Saving…' : 'Save draft'}
            </Button>
            <Button variant="outline" data-testid="grading-cancel" onClick={() => setEditing(null)}>
              Cancel
            </Button>
          </div>
        </section>
      )}

      {schemes.length === 0 && (
        <p className="text-sm text-muted-foreground" data-testid="grading-none">
          No grade scale is configured yet. Results cannot be computed until one is — nothing is assumed on your
          school&rsquo;s behalf.
        </p>
      )}

      {schemes.map((scheme) => {
        const stored = readBands(scheme.bands);
        return (
          <section
            key={scheme.id}
            className="space-y-3 rounded-lg border p-4"
            data-testid={`grading-scheme-${scheme.board}-v${scheme.version}`}
          >
            <div className="flex flex-wrap items-center gap-3">
              <h2 className="text-base font-semibold">
                {scheme.board} &middot; {scheme.name}
              </h2>
              <span className="rounded-full border px-2 py-0.5 text-xs" data-testid={`grading-status-${scheme.id}`}>
                v{scheme.version} &middot; {scheme.status} &middot; from {scheme.effective_from}
              </span>
              {canEdit && scheme.status === 'draft' && (
                <>
                  <Button variant="outline" data-testid={`grading-edit-${scheme.id}`} onClick={() => openDraft(scheme)}>
                    Edit bands
                  </Button>
                  <Button
                    disabled={busy === scheme.id || scheme.coverage_error !== null}
                    data-testid={`grading-activate-${scheme.id}`}
                    onClick={() => void onActivate(scheme.id)}
                  >
                    Activate
                  </Button>
                </>
              )}
            </div>

            {scheme.coverage_error && (
              <p className="text-sm text-destructive" data-testid={`grading-scheme-error-${scheme.id}`}>
                {scheme.coverage_error}
              </p>
            )}

            <table className="w-full text-sm">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="py-1">Grade</th>
                  <th className="py-1">From</th>
                  <th className="py-1">To</th>
                  <th className="py-1">GPA</th>
                  <th className="py-1">Pass</th>
                  <th className="py-1">Remark</th>
                </tr>
              </thead>
              <tbody>
                {stored.map((b) => (
                  <tr key={b.grade_label} data-testid={`grading-band-${scheme.id}-${b.grade_label}`}>
                    <td className="py-1 font-medium">{b.grade_label}</td>
                    <td className="py-1">{Number(b.min_pct).toFixed(2)}%</td>
                    <td className="py-1">{Number(b.max_pct).toFixed(2)}%</td>
                    <td className="py-1">{b.gpa_point === null ? '—' : Number(b.gpa_point).toFixed(2)}</td>
                    <td className="py-1">{b.is_pass ? 'Yes' : 'No'}</td>
                    <td className="py-1 text-muted-foreground">{b.remark_en ?? ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            {scheme.status === 'active' && (
              <div className="space-y-2 border-t pt-3">
                <p className="text-sm text-muted-foreground" data-testid={`grading-frozen-${scheme.id}`}>
                  These bands are frozen. Every result computed against them keeps this version even after a newer one
                  takes effect.
                </p>
                {canEdit && (
                  <div className="flex flex-wrap items-end gap-3">
                    <div className="space-y-1">
                      <Label htmlFor={`grading-new-version-date-${scheme.id}`}>New version effective from</Label>
                      <Input
                        id={`grading-new-version-date-${scheme.id}`}
                        type="date"
                        data-testid={`grading-new-version-date-${scheme.id}`}
                        value={versionDates[scheme.id] ?? ''}
                        onChange={(e) => setVersionDates((prev) => ({ ...prev, [scheme.id]: e.target.value }))}
                      />
                    </div>
                    <Button
                      variant="outline"
                      disabled={busy === scheme.id || !versionDates[scheme.id]}
                      data-testid={`grading-new-version-${scheme.id}`}
                      onClick={() => void onNewVersion(scheme.id)}
                    >
                      Start a new version
                    </Button>
                  </div>
                )}
              </div>
            )}
          </section>
        );
      })}
    </div>
  );
}

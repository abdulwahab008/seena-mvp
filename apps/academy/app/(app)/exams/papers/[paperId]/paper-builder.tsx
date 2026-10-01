'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { publishPaper, replaceQuestion } from '../actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

/** FR-I06: swap a flagged question for a fresh one without leaving the builder. */
export function ReplaceQuestionForm({ paperId, itemId }: { paperId: string; itemId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  if (!open) {
    return (
      <Button size="sm" variant="outline" onClick={() => setOpen(true)} data-testid="replace-open">
        Replace question
      </Button>
    );
  }
  return (
    <div className="space-y-2">
      <textarea aria-label="Replacement question" className="w-full rounded-md border bg-background px-3 py-2 text-sm" rows={2} value={text} onChange={(e) => setText(e.target.value)} />
      <div className="flex items-center gap-2">
        <Button
          size="sm"
          disabled={pending || text.trim().length === 0}
          data-testid="replace-save"
          onClick={() =>
            startTransition(async () => {
              const r = await replaceQuestion(paperId, { itemId, text });
              setError(r.error);
              if (!r.error) {
                toast.success('Question replaced.');
                setOpen(false);
                setText('');
                router.refresh();
              }
            })
          }
        >
          Save replacement
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setOpen(false)}>
          Cancel
        </Button>
        {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
      </div>
    </div>
  );
}

/** FR-I07: render this set's paper and its own key, then download them; every name carries the set code. */
export function PaperFilesPanel({ paperId, setCode }: { paperId: string; setCode: string }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [rendered, setRendered] = useState(false);
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-3">
        <Button
          variant="outline"
          disabled={pending}
          data-testid="render-files"
          onClick={() =>
            startTransition(async () => {
              const res = await fetch(`/api/exam-papers/${paperId}/render`, { method: 'POST' });
              if (!res.ok) {
                setError(((await res.json().catch(() => null)) as { error?: string } | null)?.error ?? 'Could not render the files.');
                return;
              }
              setError(null);
              setRendered(true);
              toast.success(`Set ${setCode} paper and answer key rendered.`);
            })
          }
        >
          Render Set {setCode} paper and key
        </Button>
        {rendered && (
          <>
            <a className="text-sm underline" href={`/api/exam-papers/${paperId}/file?kind=paper`} data-testid="download-paper">
              Download Set {setCode} paper
            </a>
            <a className="text-sm underline" href={`/api/exam-papers/${paperId}/file?kind=key`} data-testid="download-key">
              Download Set {setCode} answer key
            </a>
          </>
        )}
      </div>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </div>
  );
}

/** FR-I06: publish, asking for an override reason only when flagged questions remain. */
export function PublishPaperPanel({ paperId, flagged, mode }: { paperId: string; flagged: number; mode: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const needsReason = flagged > 0 && mode === 'block';
  return (
    <div className="space-y-3">
      {flagged > 0 && (
        <p className="text-sm text-amber-800 dark:text-amber-300" data-testid="publish-flag-note">
          {flagged} question{flagged === 1 ? ' was' : 's were'} used by this class within the cooldown.{' '}
          {mode === 'block' ? 'Replace them, or record a reason to publish anyway.' : 'You can still publish; a reason is optional.'}
        </p>
      )}
      {flagged > 0 && (
        <div className="space-y-1">
          <Label htmlFor="overrideReason">Override reason{needsReason ? ' (required)' : ' (optional)'}</Label>
          <Input id="overrideReason" className="max-w-xl" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
        </div>
      )}
      <div className="flex items-center gap-3">
        <Button
          disabled={pending}
          data-testid="publish-paper"
          onClick={() =>
            startTransition(async () => {
              const r = await publishPaper({ paperId, overrideReason: reason });
              setError(r.error);
              if (!r.error) {
                toast.success(r.overridden ? 'Published with an override.' : 'Paper published.');
                router.refresh();
              }
            })
          }
        >
          Publish paper
        </Button>
        {error && <p role="alert" className="text-sm text-destructive" data-testid="publish-paper-error">{error}</p>}
      </div>
    </div>
  );
}

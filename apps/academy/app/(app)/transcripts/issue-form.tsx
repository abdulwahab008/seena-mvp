'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { issueTranscript } from './actions';
import { TRANSCRIPT_PURPOSES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

/** FR-J13: issuing is deliberate — a purpose is required, and the serial it allocates is never reused. */
export function IssueForm({ studentId }: { studentId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [purpose, setPurpose] = useState<string>(TRANSCRIPT_PURPOSES[0]);
  const [error, setError] = useState<string | null>(null);
  const [issued, setIssued] = useState<{ serialNo: string; downloadUrl: string } | null>(null);

  const onIssue = () =>
    startTransition(async () => {
      const r = await issueTranscript({ studentId, purpose });
      setError(r.error);
      if (!r.error && r.serialNo && r.downloadUrl) {
        setIssued({ serialNo: r.serialNo, downloadUrl: r.downloadUrl });
        toast.success(`Transcript ${r.serialNo} issued.`);
        router.refresh();
      }
    });

  return (
    <div className="space-y-3" data-testid="issue-form">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="transcript-purpose">Purpose</Label>
          <select
            id="transcript-purpose"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={purpose}
            data-testid="transcript-purpose"
            onChange={(e) => setPurpose(e.target.value)}
          >
            {TRANSCRIPT_PURPOSES.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </select>
        </div>
        <Button disabled={pending} data-testid="issue-transcript" onClick={onIssue}>
          {pending ? 'Issuing…' : 'Issue transcript'}
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="issue-error">
          {error}
        </p>
      )}
      {issued && (
        <p className="text-sm" data-testid="issued-notice">
          Issued as <strong data-testid="issued-serial">{issued.serialNo}</strong>.{' '}
          <a href={issued.downloadUrl} className="underline" data-testid="issued-download">
            Download PDF
          </a>
        </p>
      )}
    </div>
  );
}

'use client';

import { useState, useTransition } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { issueLeavingCertificate, type IssueLeavingCertificateState } from './actions';

export type LeaverOption = { id: string; label: string };
export type LeavingTemplate = { value: string; label: string };
export type LeavingIssued = { id: string; serial_no: string; status: string; student: string; result: string; downloadUrl: string | null };

const control = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

export function IssueLeavingCertificate({ leavers, templates, issued }: { leavers: LeaverOption[]; templates: LeavingTemplate[]; issued: LeavingIssued[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [enrolmentId, setEnrolmentId] = useState(leavers[0]?.id ?? '');
  const [template, setTemplate] = useState(templates[0]?.value ?? '');
  const [state, setState] = useState<IssueLeavingCertificateState | null>(null);

  const issue = () => {
    const [board, language] = template.split('|');
    const fd = new FormData();
    fd.set('enrolmentId', enrolmentId);
    fd.set('boardCode', board === '_any' ? '' : (board ?? ''));
    fd.set('language', language ?? 'en');
    startTransition(async () => {
      const r = await issueLeavingCertificate(fd);
      setState(r);
      if (!r.error) {
        toast.success(`Leaving Certificate ${r.serialNo} issued.`);
        router.refresh();
      }
    });
  };

  return (
    <div className="space-y-6">
      {templates.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="slc-no-template">
          No Leaving Certificate template is active for your campus yet. Design and activate one under Certificate Templates first.
        </p>
      ) : (
        <div className="space-y-4" data-testid="slc-form">
          <div className="space-y-1">
            <Label htmlFor="slc-student">Student (Grade 10 or 12)</Label>
            <select id="slc-student" value={enrolmentId} onChange={(e) => setEnrolmentId(e.target.value)} className={control}>
              {leavers.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.label}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="slc-template">Template</Label>
            <select id="slc-template" value={template} onChange={(e) => setTemplate(e.target.value)} className={control}>
              {templates.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
          </div>
          <Button disabled={pending || !enrolmentId} onClick={issue} data-testid="slc-submit">
            {pending ? 'Issuing…' : 'Issue Leaving Certificate'}
          </Button>
          {state?.error && (
            <div className="rounded-md border border-destructive/50 p-3 text-sm text-destructive" data-testid="slc-error">
              <p>{state.error}</p>
              {state.useTransferCertificate && (
                <p className="mt-1">
                  <Link className="underline" href="/certificates/issue" data-testid="slc-offer-tc">
                    Issue a Transfer Certificate instead
                  </Link>
                </p>
              )}
            </div>
          )}
          {state && !state.error && (
            <div className="rounded-md border p-3 text-sm" data-testid="slc-result">
              Issued as <span className="font-mono">{state.serialNo}</span>. Result on the certificate: <strong data-testid="slc-result-status">{state.resultStatus}</strong>.{' '}
              {state.downloadUrl && (
                <a className="underline" href={state.downloadUrl}>
                  Download PDF
                </a>
              )}
            </div>
          )}
        </div>
      )}

      <div>
        <h2 className="mb-2 text-lg font-medium">Issued Leaving Certificates</h2>
        {issued.length === 0 ? (
          <p className="text-sm text-muted-foreground">None issued yet.</p>
        ) : (
          <div className="space-y-1 text-sm" data-testid="slc-register">
            {issued.map((r) => (
              <div key={r.id} className="flex items-center justify-between border-b py-1" data-testid="slc-row">
                <span>
                  <span className="font-mono">{r.serial_no}</span> · {r.student} · {r.result} · {r.status}
                </span>
                {r.downloadUrl && (
                  <a className="underline" href={r.downloadUrl}>
                    Download
                  </a>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

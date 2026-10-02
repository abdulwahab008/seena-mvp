'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import { submitCertificateRequest } from './actions';

export type PortalChild = { id: string; name: string };
export type PortalPurpose = { code: string; label: string; requiresJustification: boolean };
export type PortalStrings = {
  child: string;
  purpose: string;
  justification: string;
  submit: string;
  submitted: string;
  errChoose: string;
  limit: string;
  errNotFound: string;
};

const control = 'h-10 w-full rounded-md border bg-background px-2 text-sm';

export function CertificateRequestForm({ kids, purposes, strings }: { kids: PortalChild[]; purposes: PortalPurpose[]; strings: PortalStrings }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [studentId, setStudentId] = useState(kids[0]?.id ?? '');
  const [purpose, setPurpose] = useState('');
  const [justification, setJustification] = useState('');
  const [message, setMessage] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null);
  const needsText = purposes.find((p) => p.code === purpose)?.requiresJustification ?? false;

  const submit = () =>
    startTransition(async () => {
      if (!studentId || !purpose) return setMessage({ kind: 'error', text: strings.errChoose });
      const r = await submitCertificateRequest({ studentId, purpose: purpose as 'passport', justification });
      if (!r.error) {
        setMessage({ kind: 'ok', text: strings.submitted });
        setPurpose('');
        setJustification('');
        router.refresh();
      } else if (r.error === 'limit') setMessage({ kind: 'error', text: strings.limit });
      else if (r.error === 'invalid') setMessage({ kind: 'error', text: r.detail ?? strings.errChoose });
      else setMessage({ kind: 'error', text: strings.errNotFound });
    });

  return (
    <div className="space-y-3" data-testid="cert-request-form">
      <div className="space-y-1">
        <label htmlFor="cert-child" className="text-sm">
          {strings.child}
        </label>
        <select id="cert-child" value={studentId} onChange={(e) => setStudentId(e.target.value)} className={control}>
          {kids.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <label htmlFor="cert-purpose" className="text-sm">
          {strings.purpose}
        </label>
        <select id="cert-purpose" value={purpose} onChange={(e) => setPurpose(e.target.value)} className={control}>
          <option value="">—</option>
          {purposes.map((p) => (
            <option key={p.code} value={p.code}>
              {p.label}
            </option>
          ))}
        </select>
      </div>
      {needsText && (
        <div className="space-y-1">
          <label htmlFor="cert-justification" className="text-sm">
            {strings.justification}
          </label>
          <textarea id="cert-justification" rows={3} value={justification} onChange={(e) => setJustification(e.target.value)} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </div>
      )}
      <Button disabled={pending || kids.length === 0} onClick={submit} data-testid="cert-request-submit">
        {strings.submit}
      </Button>
      {message && (
        <p role={message.kind === 'error' ? 'alert' : 'status'} className={message.kind === 'error' ? 'text-sm text-destructive' : 'text-sm text-success'} data-testid="cert-request-message">
          {message.text}
        </p>
      )}
    </div>
  );
}

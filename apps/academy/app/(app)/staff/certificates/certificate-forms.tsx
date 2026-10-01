'use client';

import { useActionState, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { issueCertificate, saveTemplate, type CertificateState } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: CertificateState = { error: null };

export function IssueCertificateForm({ staff, isOwner }: { staff: { id: string; name: string }[]; isOwner: boolean }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(issueCertificate, initial);
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
  return (
    <form action={action} className="space-y-3" data-testid="issue-certificate-form">
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="staffId">Staff member</Label>
          <select id="staffId" name="staffId" required className="h-9 w-full rounded-md border bg-background px-2 text-sm">
            <option value="">Choose…</option>
            {staff.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="certType">Certificate</Label>
          <select id="certType" name="certType" className="h-9 w-full rounded-md border bg-background px-2 text-sm">
            <option value="experience">Experience certificate</option>
            <option value="service">Service certificate</option>
            <option value="noc">No objection certificate</option>
          </select>
        </div>
      </div>
      {isOwner && (
        <div className="space-y-1">
          <Label htmlFor="overrideReason">Owner override reason (only needed when the certificate is blocked)</Label>
          <Input id="overrideReason" name="overrideReason" placeholder="At least 10 characters" />
        </div>
      )}
      {state.error && (
        <p role="alert" className="text-sm text-destructive" data-testid="certificate-error">
          {state.error}
        </p>
      )}
      <Button type="submit" disabled={pending} data-testid="issue-certificate">
        Issue certificate
      </Button>
    </form>
  );
}

export function TemplateForm({ templates }: { templates: { certType: string; title: string; bodyHtml: string; numberFormat: string }[] }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(saveTemplate, initial);
  const [type, setType] = useState(templates[0]?.certType ?? 'experience');
  const current = templates.find((t) => t.certType === type);
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
  if (!current) return null;
  return (
    <form action={action} className="space-y-3" key={type} data-testid="template-form">
      <div className="space-y-1">
        <Label htmlFor="tplType">Template</Label>
        <select id="tplType" name="certType" value={type} onChange={(e) => setType(e.target.value)} className="h-9 w-full rounded-md border bg-background px-2 text-sm sm:w-64">
          {templates.map((t) => (
            <option key={t.certType} value={t.certType}>
              {t.certType}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="tplTitle">Title</Label>
        <Input id="tplTitle" name="title" defaultValue={current.title} required />
      </div>
      <div className="space-y-1">
        <Label htmlFor="tplNumber">Number format</Label>
        <Input id="tplNumber" name="numberFormat" defaultValue={current.numberFormat} required />
        <p className="text-xs text-muted-foreground">Use {'{year}'} and {'{seq4}'}, e.g. EXP-{'{year}'}-{'{seq4}'} gives EXP-2026-0043.</p>
      </div>
      <div className="space-y-1">
        <Label htmlFor="tplBody">Wording</Label>
        <textarea id="tplBody" name="bodyHtml" rows={8} defaultValue={current.bodyHtml} required className="w-full rounded-md border bg-background px-3 py-2 font-mono text-xs" />
        <p className="text-xs text-muted-foreground">
          Fields: {'{{staff_name}}'} {'{{employee_code}}'} {'{{school_name}}'} {'{{service_from}}'} {'{{service_to}}'} {'{{total_service}}'} {'{{positions}}'} {'{{designation_current}}'} {'{{certificate_no}}'} {'{{issued_on}}'}. Only simple formatting tags are kept.
        </p>
      </div>
      {state.error && <p role="alert" className="text-sm text-destructive">{state.error}</p>}
      <Button type="submit" disabled={pending}>
        Save template
      </Button>
    </form>
  );
}

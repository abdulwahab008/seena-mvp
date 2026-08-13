'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { issueTransferCertificate } from './actions';
import type { CertificateLanguageCode } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type CandidateRow = {
  id: string;
  student: { id: string; name_en: string; gr_number: string } | null;
  class_level: { name_en: string } | null;
  section: { name: string } | null;
};

export type IssuedRow = {
  id: string;
  serial_no: string;
  status: 'issued' | 'void' | 'cancelled';
  issued_at: string;
  pdf_path: string;
  revoke_reason: string | null;
  student: { name_en: string; gr_number: string } | null;
  downloadUrl: string | null;
};

export type TemplateOption = {
  id: string;
  board_code: string | null;
  language: CertificateLanguageCode;
  version: number;
  title: string;
};

const ANY_BOARD = '__any__';
const LANGUAGE_LABEL: Record<CertificateLanguageCode, string> = { en: 'English', ur: 'اردو (Urdu)' };

function templateValue(t: TemplateOption): string {
  return `${t.board_code ?? ANY_BOARD}|${t.language}`;
}

function templateLabel(t: TemplateOption): string {
  return `${t.board_code ?? 'Any board'} · ${LANGUAGE_LABEL[t.language]} · v${t.version} — ${t.title}`;
}

function candidateLabel(c: CandidateRow): string {
  const where = [c.class_level?.name_en, c.section?.name].filter(Boolean).join(' · ');
  return `${c.student?.name_en ?? 'Unknown'} (${c.student?.gr_number ?? '—'})${where ? ` — ${where}` : ''}`;
}

export function IssueTransferCertificate({
  candidates,
  issued,
  templates,
}: {
  candidates: CandidateRow[];
  issued: IssuedRow[];
  templates: TemplateOption[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  const [enrolmentId, setEnrolmentId] = useState<string>(candidates[0]?.id ?? '');
  const [leavingDate, setLeavingDate] = useState<string>(new Date().toISOString().slice(0, 10));
  const [reason, setReason] = useState('');
  const [conduct, setConduct] = useState('Good');
  const [template, setTemplate] = useState<string>(templates[0] ? templateValue(templates[0]) : '');
  // AC2's rejection has to stay on screen with the serial in it, not
  // disappear with a toast — it is the number the officer has to go and
  // find the existing document by.
  const [issueError, setIssueError] = useState<string | null>(null);
  const [lastIssued, setLastIssued] = useState<{ serialNo: string; downloadUrl?: string } | null>(null);

  const selectedCandidate = candidates.find((c) => c.id === enrolmentId) ?? null;

  const onIssue = () => {
    const [boardCode, language] = template.split('|');
    const fd = new FormData();
    fd.set('enrolmentId', enrolmentId);
    fd.set('leavingDate', leavingDate);
    fd.set('reason', reason);
    fd.set('conduct', conduct);
    fd.set('boardCode', boardCode === ANY_BOARD ? '' : (boardCode ?? ''));
    fd.set('language', language ?? 'en');

    setIssueError(null);
    setLastIssued(null);
    startTransition(async () => {
      const result = await issueTransferCertificate(fd);
      if (result.error) {
        setIssueError(result.error);
        toast.error(result.error);
        return;
      }
      setLastIssued({ serialNo: result.serialNo!, downloadUrl: result.downloadUrl });
      toast.success(`Transfer Certificate ${result.serialNo} issued.`);
      router.refresh();
    });
  };

  return (
    <div className="space-y-6">
      <Card>
        <CardContent className="space-y-4 pt-6">
          {templates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="cert-issue-no-template">
              No Transfer Certificate template is active for your campus yet. Design and activate one under Certificate
              Templates first.
            </p>
          ) : candidates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="cert-issue-no-students">
              No actively enrolled student to issue a Transfer Certificate for.
            </p>
          ) : (
            <>
              <div className="space-y-2">
                <Label htmlFor="cert-issue-student">Student</Label>
                <Select value={enrolmentId} onValueChange={setEnrolmentId}>
                  <SelectTrigger id="cert-issue-student" data-testid="cert-issue-student-trigger">
                    <SelectValue placeholder="Choose a student" />
                  </SelectTrigger>
                  <SelectContent>
                    {candidates.map((c) => (
                      <SelectItem key={c.id} value={c.id} data-testid={`cert-issue-student-${c.student?.gr_number}`}>
                        {candidateLabel(c)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {selectedCandidate && (
                  <p className="text-xs text-muted-foreground" data-testid="cert-issue-student-summary">
                    GR {selectedCandidate.student?.gr_number} · {selectedCandidate.class_level?.name_en}{' '}
                    {selectedCandidate.section?.name}
                  </p>
                )}
              </div>

              <div className="space-y-2">
                <Label htmlFor="cert-issue-template">Certificate template</Label>
                <Select value={template} onValueChange={setTemplate}>
                  <SelectTrigger id="cert-issue-template" data-testid="cert-issue-template-trigger">
                    <SelectValue placeholder="Choose a template" />
                  </SelectTrigger>
                  <SelectContent>
                    {templates.map((t) => (
                      <SelectItem key={t.id} value={templateValue(t)} data-testid={`cert-issue-template-${t.board_code ?? 'any'}-${t.language}`}>
                        {templateLabel(t)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="cert-issue-leaving-date">Date of leaving</Label>
                  <Input
                    id="cert-issue-leaving-date"
                    type="date"
                    value={leavingDate}
                    onChange={(e) => setLeavingDate(e.target.value)}
                    data-testid="cert-issue-leaving-date"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="cert-issue-conduct">Conduct</Label>
                  <Input
                    id="cert-issue-conduct"
                    value={conduct}
                    onChange={(e) => setConduct(e.target.value)}
                    placeholder="Good"
                    data-testid="cert-issue-conduct"
                  />
                </div>
              </div>

              <div className="space-y-2">
                <Label htmlFor="cert-issue-reason">Reason for leaving</Label>
                <Input
                  id="cert-issue-reason"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="Family relocation"
                  data-testid="cert-issue-reason"
                />
              </div>

              <Button onClick={onIssue} disabled={pending || !enrolmentId || !template} data-testid="cert-issue-submit">
                {pending ? 'Issuing…' : 'Issue Transfer Certificate'}
              </Button>

              {issueError && (
                <p className="rounded-md border border-destructive/50 p-3 text-sm text-destructive" data-testid="cert-issue-error">
                  {issueError}
                </p>
              )}

              {lastIssued && (
                <div className="rounded-md border p-3 text-sm" data-testid="cert-issue-result">
                  Issued as <span className="font-mono">{lastIssued.serialNo}</span>.{' '}
                  {lastIssued.downloadUrl && (
                    <a className="underline" href={lastIssued.downloadUrl} data-testid="cert-issue-download-link">
                      Download PDF
                    </a>
                  )}
                </div>
              )}
            </>
          )}
        </CardContent>
      </Card>

      <div>
        <h2 className="mb-2 text-lg font-medium">Issued Transfer Certificates</h2>
        {issued.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="cert-issue-register-empty">
            No Transfer Certificate has been issued yet.
          </p>
        ) : (
          <div className="overflow-x-auto rounded-lg border">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/50">
                  <th className="p-2 text-left font-medium">Serial</th>
                  <th className="p-2 text-left font-medium">Student</th>
                  <th className="p-2 text-left font-medium">Issued</th>
                  <th className="p-2 text-left font-medium">Status</th>
                  <th className="p-2 text-left font-medium">Document</th>
                </tr>
              </thead>
              <tbody>
                {issued.map((r) => (
                  <tr key={r.id} className="border-b last:border-0" data-testid={`cert-issue-row-${r.serial_no}`}>
                    <td className="p-2 font-mono">{r.serial_no}</td>
                    <td className="p-2">
                      {r.student?.name_en}
                      <span className="ml-2 text-xs text-muted-foreground">{r.student?.gr_number}</span>
                    </td>
                    <td className="p-2">{new Date(r.issued_at).toLocaleDateString()}</td>
                    <td className="p-2" data-testid={`cert-issue-status-${r.serial_no}`}>
                      {r.status}
                      {r.revoke_reason && <span className="ml-2 text-xs text-muted-foreground">{r.revoke_reason}</span>}
                    </td>
                    <td className="p-2">
                      {r.downloadUrl ? (
                        <a className="underline" href={r.downloadUrl} data-testid={`cert-issue-download-${r.serial_no}`}>
                          Download
                        </a>
                      ) : (
                        '—'
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

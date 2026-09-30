'use client';

import { useState, useEffect, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { issueTransferCertificate, getClearanceSummary, type ClearanceItem } from './actions';
import type { CertificateLanguageCode } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { CheckCircle2, AlertTriangle } from 'lucide-react';

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

  // FR-T04: Dues clearance gate
  const [clearanceItems, setClearanceItems] = useState<ClearanceItem[]>([]);
  const [loadingClearance, setLoadingClearance] = useState<boolean>(false);
  const [overrideReason, setOverrideReason] = useState<string>('');

  const selectedCandidate = candidates.find((c) => c.id === enrolmentId) ?? null;

  useEffect(() => {
    if (!selectedCandidate?.student?.id) {
      setClearanceItems([]);
      return;
    }
    let cancelled = false;
    setLoadingClearance(true);
    getClearanceSummary(selectedCandidate.student.id)
      .then((res) => {
        if (!cancelled) {
          setClearanceItems(res.items);
        }
      })
      .catch(() => {
        if (!cancelled) setClearanceItems([]);
      })
      .finally(() => {
        if (!cancelled) setLoadingClearance(false);
      });

    return () => {
      cancelled = true;
    };
  }, [selectedCandidate?.student?.id]);

  const hasDues = clearanceItems.length > 0;
  const totalDuesAmount = clearanceItems.reduce((sum, item) => sum + item.amount, 0);

  const onIssue = () => {
    if (hasDues && overrideReason.trim().length < 20) {
      const err = 'Outstanding dues detected. A principal override reason of at least 20 characters is required to issue this TC.';
      setIssueError(err);
      toast.error(err);
      return;
    }

    const [boardCode, language] = template.split('|');
    const fd = new FormData();
    fd.set('enrolmentId', enrolmentId);
    fd.set('leavingDate', leavingDate);
    fd.set('reason', reason);
    fd.set('conduct', conduct);
    fd.set('boardCode', boardCode === ANY_BOARD ? '' : (boardCode ?? ''));
    fd.set('language', language ?? 'en');
    if (overrideReason.trim()) {
      fd.set('overrideReason', overrideReason.trim());
    }

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

              {/* FR-T04: Dues Clearance Gate */}
              {selectedCandidate && (
                <div className="rounded-lg border p-3.5 space-y-2.5 bg-muted/20" data-testid="clearance-gate-container">
                  <div className="flex items-center justify-between text-xs">
                    <span className="font-medium text-foreground flex items-center gap-1.5">
                      Clearance Gate (FR-T04)
                    </span>
                    {loadingClearance ? (
                      <span className="text-muted-foreground">Checking dues…</span>
                    ) : hasDues ? (
                      <Badge variant="destructive" dot data-testid="clearance-status-dues">
                        Dues Outstanding (PKR {totalDuesAmount.toLocaleString()})
                      </Badge>
                    ) : (
                      <Badge variant="success" dot data-testid="clearance-status-cleared">
                        Dues Cleared
                      </Badge>
                    )}
                  </div>

                  {hasDues && (
                    <div className="space-y-3 pt-1">
                      <Alert variant="warning" className="py-2 px-3 text-xs" title="Unpaid Arrears Notice">
                        <div className="space-y-1.5 w-full">
                          <p className="text-muted-foreground">
                            This student has {clearanceItems.length} unpaid challan(s). Clearance is required before TC release or provide an authorized principal override below:
                          </p>
                          <div className="rounded border bg-background overflow-hidden">
                            <table className="w-full text-left text-xs">
                              <thead className="bg-muted/50 border-b text-[11px] text-muted-foreground">
                                <tr>
                                  <th className="p-1.5 font-medium">Challan / Item</th>
                                  <th className="p-1.5 font-medium">Amount</th>
                                  <th className="p-1.5 font-medium">Overdue</th>
                                </tr>
                              </thead>
                              <tbody className="divide-y divide-border">
                                {clearanceItems.map((item, idx) => (
                                  <tr key={idx} className="text-foreground">
                                    <td className="p-1.5">{item.description}</td>
                                    <td className="p-1.5 font-mono font-medium">PKR {item.amount.toLocaleString()}</td>
                                    <td className="p-1.5 text-muted-foreground">{item.days_outstanding} day(s)</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </div>
                        </div>
                      </Alert>

                      <div className="space-y-1.5">
                        <div className="flex items-center justify-between">
                          <Label htmlFor="cert-issue-override" className="text-xs font-semibold text-amber-900 dark:text-amber-300">
                            Principal Clearance Override (Min 20 Characters)
                          </Label>
                          <span
                            className={`text-[11px] ${
                              overrideReason.trim().length >= 20 ? 'text-success font-medium' : 'text-muted-foreground'
                            }`}
                          >
                            {overrideReason.trim().length} / 20 chars
                          </span>
                        </div>
                        <textarea
                          id="cert-issue-override"
                          value={overrideReason}
                          onChange={(e) => setOverrideReason(e.target.value)}
                          placeholder="State the reason for TC release without full clearance (e.g., Principal approved with signed parent affidavit and deferred installment plan)..."
                          className="w-full rounded-md border border-input bg-background p-2 text-xs ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 min-h-[60px]"
                          data-testid="cert-issue-override-reason"
                        />
                      </div>
                    </div>
                  )}

                  {!loadingClearance && !hasDues && (
                    <p className="text-xs text-muted-foreground flex items-center gap-1">
                      <CheckCircle2 className="h-3.5 w-3.5 text-success inline" />
                      All fee challans have been paid. No clearance override required.
                    </p>
                  )}
                </div>
              )}

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
                  <DatePicker
                    id="cert-issue-leaving-date"
                    value={leavingDate}
                    onChange={setLeavingDate}
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

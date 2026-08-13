'use client';

import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { attendanceSpan, issueCharacterCertificate, type AttendanceSpan } from './actions';
import { CHARACTER_CONDUCT_GRADES, type CertificateLanguageCode, type CharacterConductGrade } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type StudentRow = {
  id: string;
  name_en: string;
  gr_number: string;
  status: string;
};

export type IssuedRow = {
  id: string;
  serial_no: string;
  status: 'issued' | 'void' | 'cancelled';
  issued_at: string;
  pdf_path: string;
  revoke_reason: string | null;
  payload_snapshot: { values?: Record<string, string | null> } | null;
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

/** Certificates print DD-MM-YYYY (FR-T03); the derived period reads the same way. */
function printableDate(iso: string): string {
  const [y, m, d] = iso.split('-');
  return `${d}-${m}-${y}`;
}

export function IssueCharacterCertificate({
  students,
  issued,
  templates,
}: {
  students: StudentRow[];
  issued: IssuedRow[];
  templates: TemplateOption[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  const [studentId, setStudentId] = useState<string>(students[0]?.id ?? '');
  const [conduct, setConduct] = useState<CharacterConductGrade>('Excellent');
  const [periodFrom, setPeriodFrom] = useState('');
  const [periodTo, setPeriodTo] = useState('');
  const [remarks, setRemarks] = useState('');
  const [template, setTemplate] = useState<string>(templates[0] ? templateValue(templates[0]) : '');
  const [span, setSpan] = useState<AttendanceSpan | null>(null);
  const [issueError, setIssueError] = useState<string | null>(null);
  const [lastIssued, setLastIssued] = useState<{ serialNo: string; downloadUrl?: string; from?: string; to?: string } | null>(null);

  // AC1. The period is the school's own record, so it is shown BEFORE anyone
  // clicks Issue rather than typed in from memory; the fields below only
  // exist to override a history the database does not have.
  useEffect(() => {
    let current = true;
    setSpan(null);
    if (!studentId) return;
    attendanceSpan(studentId).then((result) => {
      if (current) setSpan(result);
    });
    return () => {
      current = false;
    };
  }, [studentId]);

  const onIssue = () => {
    const [boardCode, language] = template.split('|');
    const fd = new FormData();
    fd.set('studentId', studentId);
    fd.set('conduct', conduct);
    fd.set('periodFrom', periodFrom);
    fd.set('periodTo', periodTo);
    fd.set('remarks', remarks);
    fd.set('boardCode', boardCode === ANY_BOARD ? '' : (boardCode ?? ''));
    fd.set('language', language ?? 'en');

    setIssueError(null);
    setLastIssued(null);
    startTransition(async () => {
      const result = await issueCharacterCertificate(fd);
      if (result.error) {
        setIssueError(result.error);
        toast.error(result.error);
        return;
      }
      setLastIssued({
        serialNo: result.serialNo!,
        downloadUrl: result.downloadUrl,
        from: result.periodFrom,
        to: result.periodTo,
      });
      toast.success(`Character Certificate ${result.serialNo} issued.`);
      router.refresh();
    });
  };

  return (
    <div className="space-y-6">
      <Card>
        <CardContent className="space-y-4 pt-6">
          {templates.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="cc-issue-no-template">
              No Character Certificate template is active for your campus yet. Design and activate one under Certificate
              Templates first.
            </p>
          ) : students.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="cc-issue-no-students">
              No student to issue a Character Certificate for.
            </p>
          ) : (
            <>
              <div className="space-y-2">
                <Label htmlFor="cc-issue-student">Student</Label>
                <Select value={studentId} onValueChange={setStudentId}>
                  <SelectTrigger id="cc-issue-student" data-testid="cc-issue-student-trigger">
                    <SelectValue placeholder="Choose a student" />
                  </SelectTrigger>
                  <SelectContent>
                    {students.map((s) => (
                      <SelectItem key={s.id} value={s.id} data-testid={`cc-issue-student-${s.gr_number}`}>
                        {s.name_en} ({s.gr_number}) — {s.status.replace('_', ' ')}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                {span &&
                  (span.periodFrom && span.periodTo ? (
                    <p className="text-xs text-muted-foreground" data-testid="cc-issue-derived-period">
                      Attended {printableDate(span.periodFrom)} to {printableDate(span.periodTo)} · {span.enrolmentCount}{' '}
                      enrolment{span.enrolmentCount === 1 ? '' : 's'} on record
                    </p>
                  ) : (
                    <p className="text-xs text-destructive" data-testid="cc-issue-no-history">
                      No enrolment history on record — state the attendance period below.
                    </p>
                  ))}
              </div>

              <div className="space-y-2">
                <Label htmlFor="cc-issue-template">Certificate template</Label>
                <Select value={template} onValueChange={setTemplate}>
                  <SelectTrigger id="cc-issue-template" data-testid="cc-issue-template-trigger">
                    <SelectValue placeholder="Choose a template" />
                  </SelectTrigger>
                  <SelectContent>
                    {templates.map((t) => (
                      <SelectItem key={t.id} value={templateValue(t)} data-testid={`cc-issue-template-${t.board_code ?? 'any'}-${t.language}`}>
                        {templateLabel(t)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="space-y-2">
                <Label htmlFor="cc-issue-conduct">Conduct</Label>
                <Select value={conduct} onValueChange={(v) => setConduct(v as CharacterConductGrade)}>
                  <SelectTrigger id="cc-issue-conduct" data-testid="cc-issue-conduct-trigger">
                    <SelectValue placeholder="Choose a conduct grade" />
                  </SelectTrigger>
                  <SelectContent>
                    {CHARACTER_CONDUCT_GRADES.map((g) => (
                      <SelectItem key={g} value={g} data-testid={`cc-issue-conduct-${g.replace(' ', '-')}`}>
                        {g}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="cc-issue-period-from">Attended from (override)</Label>
                  <Input
                    id="cc-issue-period-from"
                    type="date"
                    value={periodFrom}
                    onChange={(e) => setPeriodFrom(e.target.value)}
                    data-testid="cc-issue-period-from"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="cc-issue-period-to">Attended to (override)</Label>
                  <Input
                    id="cc-issue-period-to"
                    type="date"
                    value={periodTo}
                    onChange={(e) => setPeriodTo(e.target.value)}
                    data-testid="cc-issue-period-to"
                  />
                </div>
              </div>
              <p className="text-xs text-muted-foreground">
                Leave both blank and the certificate states the period on record — earliest admission to last day
                attended, across every session.
              </p>

              <div className="space-y-2">
                <Label htmlFor="cc-issue-remarks">Remarks</Label>
                <Input
                  id="cc-issue-remarks"
                  value={remarks}
                  onChange={(e) => setRemarks(e.target.value)}
                  placeholder="Bore an excellent character throughout"
                  data-testid="cc-issue-remarks"
                />
              </div>

              <Button onClick={onIssue} disabled={pending || !studentId || !template} data-testid="cc-issue-submit">
                {pending ? 'Issuing…' : 'Issue Character Certificate'}
              </Button>

              {issueError && (
                <p className="rounded-md border border-destructive/50 p-3 text-sm text-destructive" data-testid="cc-issue-error">
                  {issueError}
                </p>
              )}

              {lastIssued && (
                <div className="rounded-md border p-3 text-sm" data-testid="cc-issue-result">
                  Issued as <span className="font-mono">{lastIssued.serialNo}</span>
                  {lastIssued.from && lastIssued.to && (
                    <>
                      {' '}
                      for {printableDate(lastIssued.from)} to {printableDate(lastIssued.to)}
                    </>
                  )}
                  .{' '}
                  {lastIssued.downloadUrl && (
                    <a className="underline" href={lastIssued.downloadUrl} data-testid="cc-issue-download-link">
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
        <h2 className="mb-2 text-lg font-medium">Issued Character Certificates</h2>
        {issued.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="cc-issue-register-empty">
            No Character Certificate has been issued yet.
          </p>
        ) : (
          <div className="overflow-x-auto rounded-lg border">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/50">
                  <th className="p-2 text-left font-medium">Serial</th>
                  <th className="p-2 text-left font-medium">Student</th>
                  <th className="p-2 text-left font-medium">Period</th>
                  <th className="p-2 text-left font-medium">Conduct</th>
                  <th className="p-2 text-left font-medium">Status</th>
                  <th className="p-2 text-left font-medium">Document</th>
                </tr>
              </thead>
              <tbody>
                {issued.map((r) => (
                  <tr key={r.id} className="border-b last:border-0" data-testid={`cc-issue-row-${r.serial_no}`}>
                    <td className="p-2 font-mono">{r.serial_no}</td>
                    <td className="p-2">
                      {r.student?.name_en}
                      <span className="ml-2 text-xs text-muted-foreground">{r.student?.gr_number}</span>
                    </td>
                    <td className="p-2">
                      {r.payload_snapshot?.values?.['character.period_from']} –{' '}
                      {r.payload_snapshot?.values?.['character.period_to']}
                    </td>
                    <td className="p-2">{r.payload_snapshot?.values?.['character.conduct_grade']}</td>
                    <td className="p-2" data-testid={`cc-issue-status-${r.serial_no}`}>
                      {r.status}
                      {r.revoke_reason && <span className="ml-2 text-xs text-muted-foreground">{r.revoke_reason}</span>}
                    </td>
                    <td className="p-2">
                      {r.downloadUrl ? (
                        <a className="underline" href={r.downloadUrl} data-testid={`cc-issue-download-${r.serial_no}`}>
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

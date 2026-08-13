'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { cancelCertificate, exportCertificateRegister, linkCertificateReplacement } from './actions';
import { CERTIFICATE_TYPES, type CertificateType } from '@/lib/validation';
import { CERTIFICATE_TYPE_LABELS, type RegisterFilters, type RegisterViewRow } from '@/lib/certificates/register-query';
import { continuityStatement, registerDate, type RegisterContinuity } from '@/lib/certificates/register-html';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { ALL_CAMPUSES_VALUE, buildCampusFilterOptions, type CampusOption } from '@/lib/campus-scope';

// Radix's Select.Item rejects an empty-string value; '' is the campus-scope
// module's own "All campuses" sentinel, mapped the same way every other
// filtered page here does it.
const UI_ALL_SENTINEL = '__all__';
const toUiValue = (v: string) => (v === ALL_CAMPUSES_VALUE ? UI_ALL_SENTINEL : v);
const fromUiValue = (v: string) => (v === UI_ALL_SENTINEL ? ALL_CAMPUSES_VALUE : v);

const STATUS_LABEL: Record<RegisterViewRow['status'], string> = {
  issued: 'ISSUED',
  void: 'VOID',
  cancelled: 'CANCELLED',
};

export function CertificateRegisterView({
  campuses,
  yearOptions,
  filters,
  rows,
  continuity,
}: {
  campuses: CampusOption[];
  yearOptions: number[];
  filters: RegisterFilters;
  rows: RegisterViewRow[];
  continuity: RegisterContinuity | null;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [cancelling, setCancelling] = useState<RegisterViewRow | null>(null);
  const [reason, setReason] = useState('');
  const [linking, setLinking] = useState<RegisterViewRow | null>(null);
  const [replacementId, setReplacementId] = useState('');
  const [exported, setExported] = useState<{ rowCount: number; fileName: string; downloadUrl: string } | null>(null);

  const campusOptions = buildCampusFilterOptions(campuses);

  const applyFilter = (next: Partial<{ type: string; year: string; campus: string }>) => {
    const params = new URLSearchParams({
      type: next.type ?? filters.certificateType,
      year: next.year ?? String(filters.academicYear),
    });
    const campus = next.campus ?? filters.campusId;
    if (campus) params.set('campus', campus);
    router.push(`/certificates/register?${params.toString()}`);
  };

  // The replacement offered for a cancelled entry is deliberately narrow:
  // revoke_certificate()/set_certificate_replacement() only accept a LIVE
  // certificate of the same type for the same student, so anything else
  // would be an option the database would refuse.
  const replacementOptions = (row: RegisterViewRow) =>
    rows.filter((r) => r.status === 'issued' && r.student_id === row.student_id && r.id !== row.id);

  const onCancel = () => {
    if (!cancelling) return;
    const fd = new FormData();
    fd.set('issueId', cancelling.id);
    fd.set('reason', reason);
    startTransition(async () => {
      const result = await cancelCertificate(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success(`${result.serialNo} cancelled — it keeps its number and stays in the register.`);
      setCancelling(null);
      setReason('');
      router.refresh();
    });
  };

  const onLink = () => {
    if (!linking || !replacementId) return;
    const fd = new FormData();
    fd.set('cancelledIssueId', linking.id);
    fd.set('replacementIssueId', replacementId);
    startTransition(async () => {
      const result = await linkCertificateReplacement(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success(`${result.serialNo} now cross-references ${result.replacedBySerialNo}.`);
      setLinking(null);
      setReplacementId('');
      router.refresh();
    });
  };

  const onExport = () => {
    const fd = new FormData();
    fd.set('campusId', filters.campusId);
    fd.set('certificateType', filters.certificateType);
    fd.set('academicYear', String(filters.academicYear));
    setExported(null);
    startTransition(async () => {
      const result = await exportCertificateRegister(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setExported({ rowCount: result.rowCount!, fileName: result.fileName!, downloadUrl: result.downloadUrl! });
      toast.success(`Register printed — ${result.rowCount} entries.`);
    });
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="register-type">Certificate</Label>
          <Select value={filters.certificateType} onValueChange={(v) => applyFilter({ type: v })}>
            <SelectTrigger id="register-type" className="w-56" data-testid="register-type-trigger">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {CERTIFICATE_TYPES.map((t) => (
                <SelectItem key={t} value={t} data-testid={`register-type-${t}`}>
                  {CERTIFICATE_TYPE_LABELS[t as CertificateType]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-1">
          <Label htmlFor="register-year">Academic year</Label>
          <Select value={String(filters.academicYear)} onValueChange={(v) => applyFilter({ year: v })}>
            <SelectTrigger id="register-year" className="w-32" data-testid="register-year-trigger">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {yearOptions.map((y) => (
                <SelectItem key={y} value={String(y)} data-testid={`register-year-${y}`}>
                  {y}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-1">
          <Label htmlFor="register-campus">Campus</Label>
          <Select value={toUiValue(filters.campusId)} onValueChange={(v) => applyFilter({ campus: fromUiValue(v) })}>
            <SelectTrigger id="register-campus" className="w-56" data-testid="register-campus-trigger">
              <SelectValue placeholder="All campuses" />
            </SelectTrigger>
            <SelectContent>
              {campusOptions.map((o) => (
                <SelectItem
                  key={o.value || 'all'}
                  value={toUiValue(o.value)}
                  data-testid={o.value === ALL_CAMPUSES_VALUE ? 'register-campus-all' : `register-campus-${o.value}`}
                >
                  {o.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <Button type="button" onClick={onExport} disabled={pending} data-testid="register-export-button">
          {pending ? 'Working…' : 'Export register (PDF)'}
        </Button>
      </div>

      <p className="rounded-lg border border-foreground/20 p-3 text-sm font-medium" data-testid="register-continuity">
        {continuityStatement(continuity)}
      </p>

      {exported && (
        <p className="text-sm" data-testid="register-export-result">
          {exported.rowCount} entr{exported.rowCount === 1 ? 'y' : 'ies'} printed —{' '}
          <a href={exported.downloadUrl} download={exported.fileName} className="underline" data-testid="register-export-link">
            Download the register
          </a>
        </p>
      )}

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="register-empty">
          No certificate of this type has been issued for this year.
        </p>
      ) : (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50">
                <th className="p-2 text-left font-medium">#</th>
                <th className="p-2 text-left font-medium">Serial no.</th>
                <th className="p-2 text-left font-medium">Issued on</th>
                <th className="p-2 text-left font-medium">GR no.</th>
                <th className="p-2 text-left font-medium">Student</th>
                <th className="p-2 text-left font-medium">Class</th>
                <th className="p-2 text-left font-medium">Status</th>
                <th className="p-2 text-left font-medium">Cancellation</th>
                <th className="p-2 text-left font-medium">Cross-reference</th>
                <th className="p-2 text-left font-medium" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr
                  key={row.id}
                  className={`border-b last:border-0 ${row.status === 'cancelled' ? 'bg-muted/40' : ''}`}
                  data-testid={`register-row-${row.serial_no}`}
                >
                  <td className="p-2 tabular-nums text-muted-foreground">{row.serial_seq ?? '—'}</td>
                  <td className={`p-2 font-mono ${row.status === 'issued' ? '' : 'line-through'}`}>{row.serial_no}</td>
                  <td className="p-2">{registerDate(row.issued_at)}</td>
                  <td className="p-2">{row.gr_number ?? '—'}</td>
                  <td className="p-2">{row.student_name ?? '—'}</td>
                  <td className="p-2">{[row.class_name, row.section_name].filter(Boolean).join(' · ') || '—'}</td>
                  <td className="p-2 font-medium" data-testid={`register-status-${row.serial_no}`}>
                    {STATUS_LABEL[row.status]}
                  </td>
                  <td className="p-2 text-xs text-muted-foreground">
                    {row.status === 'cancelled'
                      ? [row.cancelled_reason, row.cancelled_by_name ? `by ${row.cancelled_by_name}` : null, registerDate(row.cancelled_at)]
                          .filter(Boolean)
                          .join(' · ')
                      : row.status === 'void'
                        ? 'Document never issued'
                        : ''}
                  </td>
                  <td className="p-2 text-xs" data-testid={`register-crossref-${row.serial_no}`}>
                    {row.replaced_by_serial_no
                      ? `Replaced by ${row.replaced_by_serial_no}`
                      : row.replaces_serial_no
                        ? `Replaces ${row.replaces_serial_no}`
                        : ''}
                  </td>
                  <td className="p-2 text-right">
                    {row.status === 'issued' && (
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() => {
                          setCancelling(row);
                          setReason('');
                        }}
                        data-testid={`register-cancel-${row.serial_no}`}
                      >
                        Cancel
                      </Button>
                    )}
                    {row.status === 'cancelled' && !row.replaced_by_issue_id && (
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() => {
                          setLinking(row);
                          setReplacementId('');
                        }}
                        data-testid={`register-link-${row.serial_no}`}
                      >
                        Link replacement
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {cancelling && (
        <div className="space-y-3 rounded-lg border p-4" data-testid="register-cancel-panel">
          <div>
            <h2 className="text-lg font-medium">Cancel {cancelling.serial_no}</h2>
            <p className="text-sm text-muted-foreground">
              The entry keeps serial {cancelling.serial_no} and stays in sequence. Issue the corrected certificate afterwards —
              it takes the next number — then come back and link it here.
            </p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="cancel-reason">Reason</Label>
            <Input
              id="cancel-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="e.g. wrong date of birth"
              data-testid="register-cancel-reason"
            />
          </div>
          <div className="flex gap-2">
            <Button type="button" onClick={onCancel} disabled={pending} data-testid="register-cancel-submit">
              {pending ? 'Cancelling…' : 'Cancel this certificate'}
            </Button>
            <Button type="button" variant="outline" onClick={() => setCancelling(null)} disabled={pending}>
              Keep it
            </Button>
          </div>
        </div>
      )}

      {linking && (
        <div className="space-y-3 rounded-lg border p-4" data-testid="register-link-panel">
          <div>
            <h2 className="text-lg font-medium">Link the replacement for {linking.serial_no}</h2>
            <p className="text-sm text-muted-foreground">
              Only a live certificate of the same type for the same student can replace it, and the cross-reference is written
              once.
            </p>
          </div>
          <div className="space-y-1">
            <Label htmlFor="link-replacement">Replacement certificate</Label>
            <Select value={replacementId} onValueChange={setReplacementId}>
              <SelectTrigger id="link-replacement" className="w-72" data-testid="register-link-trigger">
                <SelectValue placeholder="Choose a certificate" />
              </SelectTrigger>
              <SelectContent>
                {replacementOptions(linking).map((r) => (
                  <SelectItem key={r.id} value={r.id} data-testid={`register-link-option-${r.serial_no}`}>
                    {r.serial_no} — {r.student_name ?? ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="flex gap-2">
            <Button type="button" onClick={onLink} disabled={pending || !replacementId} data-testid="register-link-submit">
              {pending ? 'Linking…' : 'Link replacement'}
            </Button>
            <Button type="button" variant="outline" onClick={() => setLinking(null)} disabled={pending}>
              Not now
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

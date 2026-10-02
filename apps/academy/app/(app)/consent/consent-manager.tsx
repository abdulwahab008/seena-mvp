'use client';

import { useEffect, useState, useTransition } from 'react';
import { toast } from 'sonner';
import {
  buildGalleryExport,
  getConsentEvidenceUrl,
  loadStudentConsent,
  recordConsent,
  type ConsentStateRow,
  type GuardianDecisionRow,
} from './actions';
import { CONSENT_CHANNELS, CONSENT_DECISIONS, type ConsentChannel, type ConsentDecision } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type StudentOption = { id: string; name_en: string; gr_number: string | null };

export type AttentionRow = {
  student_id: string;
  student_name: string;
  gr_number: string | null;
  purpose_code: string;
  has_conflict: boolean;
  reconsent_required: boolean;
  granted_count: number;
  denied_count: number;
  last_recorded_at: string;
};

type Guardian = { id: string; name: string; relationship: string };

const CHANNEL_LABEL: Record<ConsentChannel, string> = {
  portal: 'Parent portal',
  paper: 'Paper form',
  counter: 'At the counter',
  whatsapp: 'WhatsApp',
};

const DECISION_LABEL: Record<ConsentDecision, string> = {
  granted: 'Granted',
  denied: 'Denied',
  withdrawn: 'Withdrawn',
};

export function ConsentManager({
  campuses,
  students,
  attention,
  purposes,
  role,
}: {
  campuses: Array<{ id: string; code: string; name: string }>;
  students: StudentOption[];
  attention: AttentionRow[];
  purposes: Array<{ code: string; description_en: string; requires_explicit_grant: boolean }>;
  role: string;
}) {
  const [pending, startTransition] = useTransition();
  const [studentId, setStudentId] = useState('');
  const [detail, setDetail] = useState<{ purposes: ConsentStateRow[]; decisions: GuardianDecisionRow[]; guardians: Guardian[] } | null>(
    null,
  );

  const [purposeCode, setPurposeCode] = useState(purposes[0]?.code ?? '');
  const [guardianId, setGuardianId] = useState('');
  const [decision, setDecision] = useState<ConsentDecision>('granted');
  const [channel, setChannel] = useState<ConsentChannel>('counter');
  const [evidence, setEvidence] = useState<File | null>(null);

  const [campusId, setCampusId] = useState(campuses[0]?.id ?? '');
  const [gallery, setGallery] = useState<{ included: number; denied: number; notRecorded: number; noPhoto: number } | null>(null);

  const canBuildGallery = role === 'super_admin' || role === 'owner' || role === 'principal';

  const refresh = (id: string) => {
    startTransition(async () => {
      const result = await loadStudentConsent(id);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setDetail({ purposes: result.purposes ?? [], decisions: result.decisions ?? [], guardians: result.guardians ?? [] });
      setGuardianId((prev) => (result.guardians?.some((g) => g.id === prev) ? prev : (result.guardians?.[0]?.id ?? '')));
    });
  };

  useEffect(() => {
    if (studentId) refresh(studentId);
    else setDetail(null);
    // refresh identity is stable enough for this one-field dependency.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [studentId]);

  const onRecord = () => {
    if (!studentId || !purposeCode || !guardianId) {
      toast.error('Choose a student, a purpose and a guardian.');
      return;
    }
    if (channel === 'paper' && !evidence) {
      toast.error('A paper capture needs the signed form attached.');
      return;
    }
    const fd = new FormData();
    fd.set('studentId', studentId);
    fd.set('purposeCode', purposeCode);
    fd.set('guardianId', guardianId);
    fd.set('decision', decision);
    fd.set('channel', channel);
    if (evidence) fd.set('evidence', evidence);

    startTransition(async () => {
      const result = await recordConsent({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success(result.effective ? 'Recorded — consent is in force.' : 'Recorded — this purpose is now blocked.');
      setEvidence(null);
      refresh(studentId);
    });
  };

  const onBuildGallery = () => {
    if (!campusId) {
      toast.error('Choose a campus.');
      return;
    }
    const fd = new FormData();
    fd.set('campusId', campusId);
    startTransition(async () => {
      const result = await buildGalleryExport({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setGallery({
        included: result.included ?? 0,
        denied: result.excludedConsentDenied ?? 0,
        notRecorded: result.excludedNotRecorded ?? 0,
        noPhoto: result.excludedNoPhoto ?? 0,
      });
      toast.success(`Gallery built — ${result.included ?? 0} student${result.included === 1 ? '' : 's'} included.`);
    });
  };

  const openEvidence = (path: string) => {
    startTransition(async () => {
      const { url } = await getConsentEvidenceUrl(path);
      if (!url) {
        toast.error('Could not open the scan.');
        return;
      }
      window.open(url, '_blank', 'noopener');
    });
  };

  const conflicts = attention.filter((a) => a.has_conflict);
  const reconsent = attention.filter((a) => a.reconsent_required);

  return (
    <div className="space-y-8">
      {/* AC4 */}
      <section className="space-y-2">
        <h2 className="text-lg font-medium">Guardians who disagree</h2>
        <p className="text-sm text-muted-foreground">
          One guardian granted and another denied. The effective answer is already DENIED everywhere it is enforced — this list is
          the Principal&apos;s queue to resolve it with the family, not a switch.
        </p>
        {conflicts.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="consent-no-conflicts">
            No conflicting consents.
          </p>
        ) : (
          <div className="space-y-2">
            {conflicts.map((c) => (
              <Card key={`${c.student_id}-${c.purpose_code}`} data-testid={`consent-conflict-${c.student_name}`}>
                <CardContent className="flex items-center justify-between gap-4 p-4 text-sm">
                  <div>
                    <p className="font-medium">
                      {c.student_name}
                      {c.gr_number ? ` (GR ${c.gr_number})` : ''} · {c.purpose_code.replace(/_/g, ' ')}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {c.granted_count} granted, {c.denied_count} denied — resolves to DENIED
                    </p>
                  </div>
                  <Button type="button" variant="outline" onClick={() => setStudentId(c.student_id)}>
                    Open
                  </Button>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </section>

      {/* AC3 */}
      <section className="space-y-2">
        <h2 className="text-lg font-medium">Re-consent required</h2>
        <p className="text-sm text-muted-foreground">
          The wording of these purposes has been revised since the family agreed. Their consent is still valid and is still being
          honoured — it is flagged here so someone asks again, not invalidated behind their back.
        </p>
        {reconsent.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="consent-no-reconsent">
            Nothing is waiting on re-consent.
          </p>
        ) : (
          <div className="space-y-2">
            {reconsent.map((r) => (
              <Card key={`${r.student_id}-${r.purpose_code}`} data-testid={`consent-reconsent-${r.student_name}`}>
                <CardContent className="flex items-center justify-between gap-4 p-4 text-sm">
                  <div>
                    <p className="font-medium">
                      {r.student_name}
                      {r.gr_number ? ` (GR ${r.gr_number})` : ''} · {r.purpose_code.replace(/_/g, ' ')}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      Agreed {new Date(r.last_recorded_at).toLocaleDateString()} against an earlier version — still valid
                    </p>
                  </div>
                  <Button type="button" variant="outline" onClick={() => setStudentId(r.student_id)}>
                    Open
                  </Button>
                </CardContent>
              </Card>
            ))}
          </div>
        )}
      </section>

      {/* Per-student state + capture (AC5) */}
      <section className="space-y-4 rounded-lg border p-4">
        <h2 className="text-lg font-medium">Student consent</h2>
        <div className="space-y-1">
          <Label htmlFor="consent-student">Student</Label>
          <Select value={studentId} onValueChange={setStudentId}>
            <SelectTrigger id="consent-student" className="max-w-md" data-testid="consent-student-trigger">
              <SelectValue placeholder="Choose a student" />
            </SelectTrigger>
            <SelectContent>
              {students.map((s) => (
                <SelectItem key={s.id} value={s.id} data-testid={`consent-student-option-${s.name_en}`}>
                  {s.name_en}
                  {s.gr_number ? ` (GR ${s.gr_number})` : ''}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {detail && (
          <>
            <div className="overflow-x-auto rounded-lg border">
              <table className="w-full text-sm">
                <thead className="bg-muted/50 text-left">
                  <tr>
                    <th className="p-2">Purpose</th>
                    <th className="p-2">Effective</th>
                    <th className="p-2">Guardians</th>
                    <th className="p-2">Flags</th>
                  </tr>
                </thead>
                <tbody>
                  {detail.purposes.map((p) => (
                    <tr key={p.purpose_code} className="border-t" data-testid={`consent-purpose-${p.purpose_code}`}>
                      <td className="p-2">
                        <span className="font-medium">{p.purpose_code.replace(/_/g, ' ')}</span>
                        <span className="block text-xs text-muted-foreground">{p.description_en}</span>
                      </td>
                      <td className="p-2" data-testid={`consent-effective-${p.purpose_code}`}>
                        {p.effective ? 'Yes' : 'No'}
                      </td>
                      <td className="p-2 text-xs text-muted-foreground">
                        {p.guardian_count === 0
                          ? p.requires_explicit_grant
                            ? 'Never asked — treated as no'
                            : 'Never asked — treated as yes'
                          : `${p.granted_count} granted / ${p.denied_count} denied`}
                      </td>
                      <td className="p-2 text-xs">
                        {p.has_conflict && (
                          <span className="mr-2 text-destructive" data-testid={`consent-flag-conflict-${p.purpose_code}`}>
                            Conflict
                          </span>
                        )}
                        {p.reconsent_required && (
                          <span data-testid={`consent-flag-reconsent-${p.purpose_code}`}>Re-consent required (v{p.current_version})</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {detail.decisions.length > 0 && (
              <div className="space-y-1" data-testid="consent-decision-list">
                <h3 className="text-sm font-medium">Who said what</h3>
                {detail.decisions.map((d) => (
                  <p key={d.consent_record_id} className="text-xs text-muted-foreground">
                    {d.guardian_name} ({d.relationship}) — {d.purpose_code.replace(/_/g, ' ')}:{' '}
                    <span className="font-medium text-foreground">{DECISION_LABEL[d.decision as ConsentDecision] ?? d.decision}</span> via{' '}
                    {CHANNEL_LABEL[d.channel as ConsentChannel] ?? d.channel}, v{d.text_version},{' '}
                    {new Date(d.recorded_at).toLocaleDateString()}
                    {d.evidence_path && (
                      <>
                        {' · '}
                        <button
                          type="button"
                          className="underline"
                          data-testid={`consent-evidence-${d.consent_record_id}`}
                          onClick={() => openEvidence(d.evidence_path!)}
                        >
                          scan
                        </button>
                      </>
                    )}
                  </p>
                ))}
              </div>
            )}

            <div className="space-y-3 rounded-lg border p-3">
              <h3 className="text-sm font-medium">Record a decision</h3>
              <div className="flex flex-wrap items-end gap-3">
                <div className="space-y-1">
                  <Label htmlFor="consent-purpose">Purpose</Label>
                  <Select value={purposeCode} onValueChange={setPurposeCode}>
                    <SelectTrigger id="consent-purpose" data-testid="consent-purpose-trigger">
                      <SelectValue placeholder="Purpose" />
                    </SelectTrigger>
                    <SelectContent>
                      {purposes.map((p) => (
                        <SelectItem key={p.code} value={p.code} data-testid={`consent-purpose-option-${p.code}`}>
                          {p.code.replace(/_/g, ' ')}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor="consent-guardian">Guardian</Label>
                  <Select value={guardianId} onValueChange={setGuardianId}>
                    <SelectTrigger id="consent-guardian" data-testid="consent-guardian-trigger">
                      <SelectValue placeholder="Guardian" />
                    </SelectTrigger>
                    <SelectContent>
                      {detail.guardians.map((g) => (
                        <SelectItem key={g.id} value={g.id} data-testid={`consent-guardian-option-${g.name}`}>
                          {g.name} ({g.relationship})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor="consent-decision">Decision</Label>
                  <Select value={decision} onValueChange={(v) => setDecision(v as ConsentDecision)}>
                    <SelectTrigger id="consent-decision" data-testid="consent-decision-trigger">
                      <SelectValue placeholder="Decision" />
                    </SelectTrigger>
                    <SelectContent>
                      {CONSENT_DECISIONS.map((d) => (
                        <SelectItem key={d} value={d} data-testid={`consent-decision-option-${d}`}>
                          {DECISION_LABEL[d]}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor="consent-channel">Channel</Label>
                  <Select value={channel} onValueChange={(v) => setChannel(v as ConsentChannel)}>
                    <SelectTrigger id="consent-channel" data-testid="consent-channel-trigger">
                      <SelectValue placeholder="Channel" />
                    </SelectTrigger>
                    <SelectContent>
                      {CONSENT_CHANNELS.filter((c) => c !== 'portal').map((c) => (
                        <SelectItem key={c} value={c} data-testid={`consent-channel-option-${c}`}>
                          {CHANNEL_LABEL[c]}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              </div>

              {/* AC5 */}
              <div className="space-y-1">
                <Label htmlFor="consent-evidence">
                  Signed form {channel === 'paper' ? '(required for a paper capture)' : '(optional)'}
                </Label>
                <input
                  id="consent-evidence"
                  type="file"
                  accept="image/jpeg,image/png,application/pdf"
                  data-testid="consent-evidence-input"
                  className="block text-sm"
                  onChange={(e) => setEvidence(e.target.files?.[0] ?? null)}
                />
              </div>

              <Button type="button" disabled={pending} onClick={onRecord} data-testid="consent-record-button">
                {pending ? 'Recording…' : 'Record decision'}
              </Button>
            </div>
          </>
        )}
      </section>

      {/* AC1 */}
      {canBuildGallery && (
        <section className="space-y-3 rounded-lg border p-4">
          <h2 className="text-lg font-medium">Marketing gallery export</h2>
          <p className="text-sm text-muted-foreground">
            Assembles the student photographs the school may actually publish. A student without a live photo-marketing grant is
            left out and the exclusion is written to the audit trail — there is no override.
          </p>
          <div className="flex flex-wrap items-end gap-3">
            <div className="space-y-1">
              <Label htmlFor="gallery-campus">Campus</Label>
              <Select value={campusId} onValueChange={setCampusId}>
                <SelectTrigger id="gallery-campus" data-testid="gallery-campus-trigger">
                  <SelectValue placeholder="Campus" />
                </SelectTrigger>
                <SelectContent>
                  {campuses.map((c) => (
                    <SelectItem key={c.id} value={c.id} data-testid={`gallery-campus-option-${c.code}`}>
                      {c.name} ({c.code})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <Button type="button" disabled={pending} onClick={onBuildGallery} data-testid="gallery-build-button">
              {pending ? 'Building…' : 'Build gallery'}
            </Button>
          </div>
          {gallery && (
            <p className="text-sm" data-testid="gallery-result">
              {gallery.included} included · {gallery.denied} excluded (consent denied) · {gallery.notRecorded} excluded (no consent
              on file) · {gallery.noPhoto} excluded (no photograph)
            </p>
          )}
        </section>
      )}
    </div>
  );
}

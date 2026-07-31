'use client';

import { useRef, useState, useTransition } from 'react';
import { toast } from 'sonner';
import {
  issueOffer,
  respondToOffer,
  joinWaitlist,
  removeFromWaitlist,
  checkChecklistCompleteness,
  setDocumentSubmission,
  uploadAdmissionDocument,
  verifyDocument,
  rejectDocument,
  deleteDocument,
  getDocumentSignedUrl,
  recordAdmissionFeePayment,
  reconcileAdmissionFeePayment,
  waiveAdmissionFee,
  enrolFromOffer,
  type MissingItem,
} from './actions';
import { OFFER_DECLINE_REASONS, DOC_STATUSES, DOCUMENT_TYPES, FEE_PAYMENT_MODES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type DocumentRow = {
  id: string;
  docType: string;
  status: string;
  rejectReason: string | null;
  bFormNo: string | null;
};

export type PaymentRow = { id: string; amountPaisa: number; mode: string; status: string; consumed: boolean };
export type WaiverRow = { id: string; reason: string; consumed: boolean };
export type SectionOption = { id: string; name: string };

export type ApplicationRow = {
  id: string;
  applicationNo: string | null;
  status: string;
  childName: string;
  className: string;
  offer: {
    id: string;
    status: string;
    expires_at: string;
    admission_fee_amount: number;
    expiry_paused_at: string | null;
    expiry_pause_reason: string | null;
  } | null;
  availableSeats: number | null;
  waitlist: { id: string; position: number | null; status: string } | null;
  checklistSnapshot: { doc_type: string; is_mandatory: boolean; min_count: number }[];
  documents: DocumentRow[];
  payments: PaymentRow[];
  waivers: WaiverRow[];
  sections: SectionOption[];
};

function ChecklistPanel({ applicationId, docTypes }: { applicationId: string; docTypes: string[] }) {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<{ complete: boolean; missing: MissingItem[] } | null>(null);
  const [docType, setDocType] = useState(docTypes[0] ?? '');
  const [status, setStatus] = useState('uploaded');
  const [count, setCount] = useState('');
  const [deadline, setDeadline] = useState('');

  const onCheck = () => {
    startTransition(async () => {
      const r = await checkChecklistCompleteness(applicationId);
      if (r.error) toast.error(r.error);
      else setResult({ complete: r.complete!, missing: r.missing! });
    });
  };

  const onSave = () => {
    const fd = new FormData();
    fd.set('applicationId', applicationId);
    fd.set('docType', docType);
    fd.set('status', status);
    if (count) fd.set('uploadedCount', count);
    if (deadline) fd.set('promisedDeadline', deadline);
    startTransition(async () => {
      const r = await setDocumentSubmission({ error: null }, fd);
      if (r.error) toast.error(r.error);
      else {
        toast.success('Document status saved.');
        onCheck();
      }
    });
  };

  if (docTypes.length === 0) return null;

  return (
    <div className="mt-2 space-y-2 border-t pt-2" data-testid={`checklist-panel-${applicationId}`}>
      <div className="flex items-center gap-2">
        <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onCheck}>
          Check checklist
        </Button>
        {result && (
          <span className="text-xs" data-testid={`checklist-result-${applicationId}`}>
            {result.complete
              ? 'Complete'
              : `Incomplete — missing: ${result.missing.map((m) => `${m.doc_type.replace(/_/g, ' ')} (${m.missing})`).join(', ')}`}
          </span>
        )}
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <Select value={docType} onValueChange={setDocType}>
          <SelectTrigger className="h-8 w-40" data-testid={`checklist-doctype-trigger-${applicationId}`}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {docTypes.map((d) => (
              <SelectItem key={d} value={d}>
                {d.replace(/_/g, ' ')}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={status} onValueChange={setStatus}>
          <SelectTrigger className="h-8 w-32" data-testid={`checklist-status-trigger-${applicationId}`}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {DOC_STATUSES.map((s) => (
              <SelectItem key={s} value={s}>
                {s}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {status === 'uploaded' && (
          <Input placeholder="Count" type="number" className="h-8 w-20" value={count} onChange={(e) => setCount(e.target.value)} />
        )}
        {status === 'promised' && (
          <Input type="date" className="h-8 w-40" value={deadline} onChange={(e) => setDeadline(e.target.value)} />
        )}
        <Button type="button" size="sm" disabled={pending} onClick={onSave}>
          Save
        </Button>
      </div>
    </div>
  );
}

function DocumentUploadForm({ applicationId }: { applicationId: string }) {
  const [pending, startTransition] = useTransition();
  const [docType, setDocType] = useState<string>(DOCUMENT_TYPES[0]);
  const [bFormNo, setBFormNo] = useState('');
  const [fileError, setFileError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const onSubmit = (formData: FormData) => {
    const file = formData.get('file') as File | null;
    if (file && file.size > 5 * 1024 * 1024) {
      setFileError('Maximum file size 5 MB');
      return;
    }
    setFileError(null);
    formData.set('applicationId', applicationId);
    formData.set('docType', docType);
    if (bFormNo) formData.set('bFormNo', bFormNo);

    startTransition(async () => {
      const result = await uploadAdmissionDocument({ error: null }, formData);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Document uploaded.');
        setBFormNo('');
        if (inputRef.current) inputRef.current.value = '';
      }
    });
  };

  return (
    <form action={onSubmit} className="flex flex-wrap items-end gap-2" data-testid={`document-upload-form-${applicationId}`}>
      <Select value={docType} onValueChange={setDocType}>
        <SelectTrigger className="h-8 w-40" data-testid={`document-doctype-trigger-${applicationId}`}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {DOCUMENT_TYPES.map((d) => (
            <SelectItem key={d} value={d}>
              {d.replace(/_/g, ' ')}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {docType === 'b_form' && (
        <Input
          placeholder="42101-1234567-8"
          className="h-8 w-40"
          value={bFormNo}
          onChange={(e) => setBFormNo(e.target.value)}
          data-testid={`document-bform-no-${applicationId}`}
        />
      )}
      <input
        ref={inputRef}
        name="file"
        type="file"
        accept="image/jpeg,image/png,application/pdf"
        className="h-8 text-xs"
        data-testid={`document-file-input-${applicationId}`}
      />
      <Button type="submit" size="sm" disabled={pending} data-testid={`document-upload-submit-${applicationId}`}>
        {pending ? 'Uploading…' : 'Upload'}
      </Button>
      {fileError && <p className="w-full text-xs text-destructive">{fileError}</p>}
    </form>
  );
}

function DocumentRejectControl({ documentId }: { documentId: string }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');
  const [open, setOpen] = useState(false);

  const onReject = () => {
    const fd = new FormData();
    fd.set('documentId', documentId);
    fd.set('reason', reason);
    startTransition(async () => {
      const result = await rejectDocument({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Document rejected.');
        setOpen(false);
        setReason('');
      }
    });
  };

  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)}>
        Reject
      </Button>
    );
  }

  return (
    <div className="flex items-center gap-1">
      <Input
        placeholder="Reason"
        className="h-7 w-32"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        data-testid={`document-reject-reason-${documentId}`}
      />
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={onReject} data-testid={`document-reject-submit-${documentId}`}>
        Confirm
      </Button>
    </div>
  );
}

function DocumentsPanel({ applicationId, documents }: { applicationId: string; documents: DocumentRow[] }) {
  const [pending, startTransition] = useTransition();
  const [previewUrl, setPreviewUrl] = useState<Record<string, string>>({});

  const onVerify = (documentId: string) => {
    startTransition(async () => {
      const result = await verifyDocument(documentId);
      if (result.error) toast.error(result.error);
      else toast.success('Document verified.');
    });
  };

  const onDelete = (documentId: string) => {
    startTransition(async () => {
      const result = await deleteDocument(documentId);
      if (result.error) toast.error(result.error);
      else toast.success('Document deleted.');
    });
  };

  const onPreview = (documentId: string) => {
    startTransition(async () => {
      const result = await getDocumentSignedUrl(documentId);
      if (result.error) toast.error(result.error);
      else if (result.url) setPreviewUrl((p) => ({ ...p, [documentId]: result.url! }));
    });
  };

  return (
    <div className="mt-2 space-y-2 border-t pt-2" data-testid={`documents-panel-${applicationId}`}>
      <DocumentUploadForm applicationId={applicationId} />
      {documents.length > 0 && (
        <ul className="space-y-1 text-xs">
          {documents.map((d) => (
            <li key={d.id} className="flex flex-wrap items-center gap-2" data-testid={`document-row-${d.id}`}>
              <span className="w-32 shrink-0">{d.docType.replace(/_/g, ' ')}</span>
              <span data-testid={`document-status-${d.id}`}>{d.status}</span>
              {d.status === 'rejected' && d.rejectReason && <span className="text-muted-foreground">({d.rejectReason})</span>}
              <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => onPreview(d.id)}>
                Preview
              </Button>
              {previewUrl[d.id] && (
                <a href={previewUrl[d.id]} target="_blank" rel="noreferrer" className="text-blue-600 underline" data-testid={`document-preview-link-${d.id}`}>
                  Open
                </a>
              )}
              {d.status !== 'verified' && (
                <Button type="button" size="sm" disabled={pending} onClick={() => onVerify(d.id)}>
                  Verify
                </Button>
              )}
              {d.status !== 'rejected' && <DocumentRejectControl documentId={d.id} />}
              <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => onDelete(d.id)} data-testid={`document-delete-${d.id}`}>
                Delete
              </Button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function JoinWaitlistButton({ applicationId }: { applicationId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await joinWaitlist(applicationId);
      if (result.error) toast.error(result.error);
      else toast.success('Added to the waitlist.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick}>
      {pending ? 'Adding…' : 'Join waitlist'}
    </Button>
  );
}

function WaitlistBadge({ waitlist }: { waitlist: { id: string; position: number | null; status: string } }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');

  const onRemove = () => {
    if (!reason.trim()) {
      toast.error('Enter a reason for removing this applicant.');
      return;
    }
    startTransition(async () => {
      const result = await removeFromWaitlist(waitlist.id, reason);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Removed from the waitlist.');
        setReason('');
      }
    });
  };

  if (waitlist.status === 'offer_pending') {
    return (
      <span className="text-xs text-muted-foreground" data-testid={`waitlist-status-${waitlist.id}`}>
        Promoted — ready for an offer
      </span>
    );
  }

  return (
    <div className="flex items-center gap-2" data-testid={`waitlist-status-${waitlist.id}`}>
      <span className="text-xs text-muted-foreground">Waitlist position {waitlist.position}</span>
      <Input
        placeholder="Removal reason"
        className="h-8 w-40"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
      />
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onRemove}>
        Remove
      </Button>
    </div>
  );
}

function IssueOfferForm({ applicationId, availableSeats }: { applicationId: string; availableSeats: number }) {
  const [pending, startTransition] = useTransition();
  const [fee, setFee] = useState('');

  const onClick = () => {
    const amount = Number(fee);
    if (!fee || !(amount > 0)) {
      toast.error('Enter a fee amount.');
      return;
    }
    const fd = new FormData();
    fd.set('feeAmount', fee);
    startTransition(async () => {
      const result = await issueOffer(applicationId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Offer issued.');
        setFee('');
      }
    });
  };

  return (
    <div className="flex items-end gap-2">
      <div className="space-y-1">
        <Label htmlFor={`fee-${applicationId}`}>Admission fee</Label>
        <Input
          id={`fee-${applicationId}`}
          type="number"
          step="0.01"
          placeholder="5000"
          className="w-28"
          value={fee}
          onChange={(e) => setFee(e.target.value)}
        />
      </div>
      <Button type="button" size="sm" disabled={pending || availableSeats <= 0} onClick={onClick}>
        {availableSeats <= 0 ? 'No seats' : pending ? 'Issuing…' : 'Issue offer'}
      </Button>
    </div>
  );
}

function AcceptButton({ offerId }: { offerId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('response', 'accepted');
    startTransition(async () => {
      const result = await respondToOffer({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Offer accepted.');
    });
  };

  return (
    <Button type="button" size="sm" disabled={pending} onClick={onClick}>
      Accept
    </Button>
  );
}

function DeclineControl({ offerId }: { offerId: string }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');

  const onClick = () => {
    if (!reason) {
      toast.error('Choose a decline reason.');
      return;
    }
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('response', 'declined');
    fd.set('declineReason', reason);
    startTransition(async () => {
      const result = await respondToOffer({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Offer declined.');
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Select value={reason} onValueChange={setReason}>
        <SelectTrigger className="h-9 w-40" data-testid={`decline-reason-trigger-${offerId}`}>
          <SelectValue placeholder="Reason" />
        </SelectTrigger>
        <SelectContent>
          {OFFER_DECLINE_REASONS.map((r) => (
            <SelectItem key={r} value={r}>
              {r.replace(/_/g, ' ')}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={onClick}>
        Decline
      </Button>
    </div>
  );
}

function RecordPaymentForm({ offerId }: { offerId: string }) {
  const [pending, startTransition] = useTransition();
  const [amount, setAmount] = useState('');
  const [mode, setMode] = useState<(typeof FEE_PAYMENT_MODES)[number]>('cash');
  const [referenceNo, setReferenceNo] = useState('');

  const onSubmit = () => {
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('amountRupees', amount);
    fd.set('mode', mode);
    if (referenceNo) fd.set('referenceNo', referenceNo);
    startTransition(async () => {
      const result = await recordAdmissionFeePayment({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Payment recorded.');
        setAmount('');
        setReferenceNo('');
      }
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-2" data-testid={`record-payment-form-${offerId}`}>
      <div className="space-y-1">
        <Label htmlFor={`payment-amount-${offerId}`}>Amount (PKR)</Label>
        <Input
          id={`payment-amount-${offerId}`}
          type="number"
          step="0.01"
          className="h-8 w-28"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          data-testid={`payment-amount-${offerId}`}
        />
      </div>
      <Select value={mode} onValueChange={(v) => setMode(v as (typeof FEE_PAYMENT_MODES)[number])}>
        <SelectTrigger className="h-8 w-32" data-testid={`payment-mode-trigger-${offerId}`}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {FEE_PAYMENT_MODES.map((m) => (
            <SelectItem key={m} value={m}>
              {m.replace(/_/g, ' ')}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Input
        placeholder="Reference no."
        className="h-8 w-32"
        value={referenceNo}
        onChange={(e) => setReferenceNo(e.target.value)}
      />
      <Button type="button" size="sm" disabled={pending} onClick={onSubmit} data-testid={`record-payment-submit-${offerId}`}>
        Record payment
      </Button>
    </div>
  );
}

function ReconcileButton({ paymentId }: { paymentId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await reconcileAdmissionFeePayment(paymentId);
      if (result.error) toast.error(result.error);
      else toast.success('Payment reconciled.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick} data-testid={`reconcile-payment-${paymentId}`}>
      Reconcile
    </Button>
  );
}

function WaiveFeeForm({ offerId }: { offerId: string }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');
  const [open, setOpen] = useState(false);

  const onSubmit = () => {
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('reason', reason);
    startTransition(async () => {
      const result = await waiveAdmissionFee({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Fee waived.');
        setOpen(false);
        setReason('');
      }
    });
  };

  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)} data-testid={`waive-fee-open-${offerId}`}>
        Waive fee
      </Button>
    );
  }

  return (
    <div className="flex items-center gap-1">
      <Input
        placeholder="Waiver reason (min 10 chars)"
        className="h-8 w-56"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        data-testid={`waive-fee-reason-${offerId}`}
      />
      <Button type="button" size="sm" disabled={pending} onClick={onSubmit} data-testid={`waive-fee-submit-${offerId}`}>
        Confirm waiver
      </Button>
    </div>
  );
}

function EnrolForm({
  offerId,
  sections,
  fundingOptions,
}: {
  offerId: string;
  sections: SectionOption[];
  fundingOptions: { value: string; label: string }[];
}) {
  const [pending, startTransition] = useTransition();
  const [sectionId, setSectionId] = useState(sections[0]?.id ?? '');
  const [gender, setGender] = useState<'male' | 'female' | 'other'>('male');
  const [funding, setFunding] = useState(fundingOptions[0]?.value ?? '');

  const onSubmit = () => {
    if (!funding) {
      toast.error('Record a payment or waive the fee before enrolling.');
      return;
    }
    const [kind, ...idParts] = funding.split(':');
    const id = idParts.join(':');
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('sectionId', sectionId);
    fd.set('gender', gender);
    if (kind === 'payment') fd.set('paymentId', id);
    else fd.set('waiverId', id);
    startTransition(async () => {
      const result = await enrolFromOffer({ error: null, grNumber: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success(`Enrolled — GR ${result.grNumber}.`);
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-2 border-t pt-2" data-testid={`enrol-form-${offerId}`}>
      <Select value={sectionId} onValueChange={setSectionId}>
        <SelectTrigger className="h-8 w-32" data-testid={`enrol-section-trigger-${offerId}`}>
          <SelectValue placeholder="Section" />
        </SelectTrigger>
        <SelectContent>
          {sections.map((s) => (
            <SelectItem key={s.id} value={s.id}>
              {s.name}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Select value={gender} onValueChange={(v) => setGender(v as 'male' | 'female' | 'other')}>
        <SelectTrigger className="h-8 w-24" data-testid={`enrol-gender-trigger-${offerId}`}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="male">Male</SelectItem>
          <SelectItem value="female">Female</SelectItem>
          <SelectItem value="other">Other</SelectItem>
        </SelectContent>
      </Select>
      <Select value={funding} onValueChange={setFunding}>
        <SelectTrigger className="h-8 w-56" data-testid={`enrol-funding-trigger-${offerId}`}>
          <SelectValue placeholder="Fund with…" />
        </SelectTrigger>
        <SelectContent>
          {fundingOptions.map((f) => (
            <SelectItem key={f.value} value={f.value}>
              {f.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button type="button" size="sm" disabled={pending || !sectionId} onClick={onSubmit} data-testid={`enrol-submit-${offerId}`}>
        {pending ? 'Enrolling…' : 'Enrol'}
      </Button>
    </div>
  );
}

function EnrolmentPanel({
  applicationId,
  offer,
  payments,
  waivers,
  sections,
}: {
  applicationId: string;
  offer: NonNullable<ApplicationRow['offer']>;
  payments: PaymentRow[];
  waivers: WaiverRow[];
  sections: SectionOption[];
}) {
  const feeRupees = (offer.admission_fee_amount).toLocaleString();
  const fundingOptions = [
    ...payments
      .filter((p) => !p.consumed)
      .map((p) => ({ value: `payment:${p.id}`, label: `Payment PKR ${(p.amountPaisa / 100).toLocaleString()} (${p.mode}, ${p.status})` })),
    ...waivers.filter((w) => !w.consumed).map((w) => ({ value: `waiver:${w.id}`, label: `Waiver — ${w.reason}` })),
  ];

  return (
    <div className="mt-2 space-y-2 border-t pt-2" data-testid={`enrolment-panel-${applicationId}`}>
      <p className="text-xs text-muted-foreground">Admission fee: PKR {feeRupees}</p>
      {offer.expiry_paused_at && (
        <p className="text-xs text-amber-600" data-testid={`offer-paused-${offer.id}`}>
          Expiry paused — {offer.expiry_pause_reason}
        </p>
      )}
      {payments.length > 0 && (
        <ul className="space-y-1 text-xs">
          {payments.map((p) => (
            <li key={p.id} className="flex items-center gap-2" data-testid={`payment-row-${p.id}`}>
              <span>
                PKR {(p.amountPaisa / 100).toLocaleString()} · {p.mode} ·{' '}
                <span data-testid={`payment-status-${p.id}`}>{p.status}</span>
                {p.consumed && ' · used'}
              </span>
              {p.status === 'provisional' && !p.consumed && <ReconcileButton paymentId={p.id} />}
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <RecordPaymentForm offerId={offer.id} />
        <WaiveFeeForm offerId={offer.id} />
      </div>
      <EnrolForm offerId={offer.id} sections={sections} fundingOptions={fundingOptions} />
    </div>
  );
}

export function ApplicationList({ applications }: { applications: ApplicationRow[] }) {
  if (applications.length === 0) {
    return <p className="text-sm text-muted-foreground">No applications yet.</p>;
  }

  return (
    <div className="space-y-2">
      {applications.map((a) => (
        <Card key={a.id} data-testid={`application-row-${a.applicationNo}`}>
          <CardContent className="p-4">
            <div className="flex items-center justify-between gap-4">
              <div>
                <p className="font-medium">
                  {a.childName} <span className="text-muted-foreground">({a.applicationNo})</span>
                </p>
                <p className="text-sm text-muted-foreground">
                  {a.className} · <span data-testid={`application-status-${a.applicationNo}`}>{a.status}</span>
                  {a.offer && a.offer.status === 'issued' && ` · offer expires ${new Date(a.offer.expires_at).toLocaleDateString()}`}
                </p>
              </div>
              {a.offer && a.offer.status === 'issued' ? (
                <div className="flex items-center gap-2">
                  <AcceptButton offerId={a.offer.id} />
                  <DeclineControl offerId={a.offer.id} />
                </div>
              ) : a.waitlist ? (
                <WaitlistBadge waitlist={a.waitlist} />
              ) : (
                !a.offer &&
                a.availableSeats !== null && (
                  <div className="flex items-center gap-3">
                    <span className="text-xs text-muted-foreground" data-testid={`available-seats-${a.applicationNo}`}>
                      {a.availableSeats} seat(s) left
                    </span>
                    {a.availableSeats > 0 ? (
                      <IssueOfferForm applicationId={a.id} availableSeats={a.availableSeats} />
                    ) : (
                      <JoinWaitlistButton applicationId={a.id} />
                    )}
                  </div>
                )
              )}
            </div>
            <ChecklistPanel applicationId={a.id} docTypes={a.checklistSnapshot.map((d) => d.doc_type)} />
            <DocumentsPanel applicationId={a.id} documents={a.documents} />
            {a.offer && a.offer.status === 'accepted' && (
              <EnrolmentPanel applicationId={a.id} offer={a.offer} payments={a.payments} waivers={a.waivers} sections={a.sections} />
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import {
  createRequisitionAction,
  decideRequisitionAction,
  postGoodsReceiptAction,
  saveThresholdsAction,
  submitRequisitionAction,
  updateRequisitionAction,
} from './actions';

type Option = { value: string; label: string };
const control = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

export type LineDraft = { itemId: string; description: string; qty: string; estUnitCostPkr: string };
const blankLine = (): LineDraft => ({ itemId: '', description: '', qty: '1', estUnitCostPkr: '' });

export function RequisitionForm({
  campuses,
  departments,
  items,
  reqId,
  initial,
}: {
  campuses: Option[];
  departments: Option[];
  items: (Option & { name: string })[];
  reqId?: string;
  initial?: { campusId: string; departmentId: string; justification: string; lines: LineDraft[] };
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [campusId, setCampusId] = useState(initial?.campusId ?? campuses[0]?.value ?? '');
  const [departmentId, setDepartmentId] = useState(initial?.departmentId ?? '');
  const [justification, setJustification] = useState(initial?.justification ?? '');
  const [lines, setLines] = useState<LineDraft[]>(initial?.lines.length ? initial.lines : [blankLine()]);

  const patch = (i: number, p: Partial<LineDraft>) => setLines(lines.map((l, idx) => (idx === i ? { ...l, ...p } : l)));
  const total = lines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(l.estUnitCostPkr) || 0), 0);

  const submit = () =>
    startTransition(async () => {
      const payload = { campusId, departmentId, justification, lines: lines.map((l) => ({ ...l, qty: Number(l.qty), estUnitCostPkr: Number(l.estUnitCostPkr) })) };
      const r = reqId ? await updateRequisitionAction(reqId, payload) : await createRequisitionAction(payload);
      setError(r.error);
      if (!r.error) {
        toast.success(reqId ? 'Requisition updated.' : 'Requisition saved as a draft.');
        if (!reqId && 'reqId' in r && r.reqId) router.push(`/purchasing/${r.reqId}`);
        else router.refresh();
      }
    });

  return (
    <div className="space-y-3" data-testid="requisition-form">
      <div className="grid gap-3 sm:grid-cols-2">
        {!reqId && (
          <div className="space-y-1">
            <Label htmlFor="req-campus">Campus</Label>
            <select id="req-campus" value={campusId} onChange={(e) => setCampusId(e.target.value)} className={control}>
              {campuses.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
          </div>
        )}
        {!reqId && (
          <div className="space-y-1">
            <Label htmlFor="req-department">Department</Label>
            <select id="req-department" value={departmentId} onChange={(e) => setDepartmentId(e.target.value)} className={control}>
              <option value="">None</option>
              {departments.map((d) => (
                <option key={d.value} value={d.value}>
                  {d.label}
                </option>
              ))}
            </select>
          </div>
        )}
        <div className="space-y-1 sm:col-span-2">
          <Label htmlFor="req-justification">Justification</Label>
          <textarea id="req-justification" rows={2} value={justification} onChange={(e) => setJustification(e.target.value)} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </div>
      </div>
      <div className="space-y-2">
        {lines.map((l, i) => (
          <div key={i} className="grid grid-cols-12 gap-2" data-testid="req-line">
            <select aria-label={`Item ${i + 1}`} value={l.itemId} onChange={(e) => patch(i, { itemId: e.target.value, description: l.description || items.find((it) => it.value === e.target.value)?.name || '' })} className={`${control} col-span-3`}>
              <option value="">Not in stock list</option>
              {items.map((it) => (
                <option key={it.value} value={it.value}>
                  {it.label}
                </option>
              ))}
            </select>
            <input aria-label={`Description ${i + 1}`} placeholder="Description" value={l.description} onChange={(e) => patch(i, { description: e.target.value })} className={`${control} col-span-4`} />
            <input aria-label={`Quantity ${i + 1}`} type="number" min={0} step="any" value={l.qty} onChange={(e) => patch(i, { qty: e.target.value })} className={`${control} col-span-2`} />
            <input aria-label={`Unit cost ${i + 1} (PKR)`} type="number" min={0} step="any" placeholder="PKR each" value={l.estUnitCostPkr} onChange={(e) => patch(i, { estUnitCostPkr: e.target.value })} className={`${control} col-span-2`} />
            <Button type="button" variant="ghost" size="sm" className="col-span-1" disabled={lines.length === 1} onClick={() => setLines(lines.filter((_, idx) => idx !== i))}>
              Remove
            </Button>
          </div>
        ))}
        <Button type="button" variant="outline" size="sm" onClick={() => setLines([...lines, blankLine()])} data-testid="add-line">
          Add item
        </Button>
      </div>
      <p className="text-sm font-medium" data-testid="req-estimate">
        Estimated total PKR {total.toLocaleString('en-PK')}
      </p>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="req-error">
          {error}
        </p>
      )}
      <Button type="button" disabled={pending} onClick={submit} data-testid="req-save">
        {reqId ? 'Save changes' : 'Save draft'}
      </Button>
    </div>
  );
}

export function SubmitButton({ reqId }: { reqId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="inline-flex items-center gap-2">
      <Button
        disabled={pending}
        data-testid="req-submit"
        onClick={() =>
          startTransition(async () => {
            const r = await submitRequisitionAction(reqId);
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Submit for approval
      </Button>
      {error && (
        <span role="alert" className="text-sm text-destructive">
          {error}
        </span>
      )}
    </span>
  );
}

export function DecisionButtons({ reqId }: { reqId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [remarks, setRemarks] = useState('');
  const decide = (decision: 'approve' | 'reject') =>
    startTransition(async () => {
      const r = await decideRequisitionAction(reqId, decision, remarks);
      setError(r.error);
      if (!r.error) {
        toast.success(decision === 'approve' ? 'Approved.' : 'Rejected.');
        router.refresh();
      }
    });
  return (
    <div className="space-y-2" data-testid="decision-buttons">
      <input aria-label="Remarks" placeholder="Remarks (required to reject)" value={remarks} onChange={(e) => setRemarks(e.target.value)} className={control} />
      <div className="flex gap-2">
        <Button disabled={pending} onClick={() => decide('approve')} data-testid="req-approve">
          Approve
        </Button>
        <Button variant="outline" disabled={pending} onClick={() => decide('reject')} data-testid="req-reject">
          Reject
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="decision-error">
          {error}
        </p>
      )}
    </div>
  );
}

const ROLES: Option[] = [
  { value: 'principal', label: 'Principal' },
  { value: 'vice_principal', label: 'Vice Principal' },
  { value: 'accountant', label: 'Accountant' },
  { value: 'hr_manager', label: 'HR Manager' },
  { value: 'owner', label: 'Director / Owner' },
];

export function ThresholdForm({ initial }: { initial: { uptoPkr: string; role: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [tiers, setTiers] = useState(initial.length ? initial : [{ uptoPkr: '50000', role: 'principal' }, { uptoPkr: '', role: 'owner' }]);
  const patch = (i: number, p: Partial<{ uptoPkr: string; role: string }>) => setTiers(tiers.map((t, idx) => (idx === i ? { ...t, ...p } : t)));
  return (
    <div className="space-y-3" data-testid="threshold-form">
      {tiers.map((t, i) => (
        <div key={i} className="grid grid-cols-12 items-end gap-2">
          <div className="col-span-3 text-sm text-muted-foreground">Tier {i + 1}</div>
          <div className="col-span-4 space-y-1">
            <Label htmlFor={`tier-limit-${i}`}>Up to (PKR)</Label>
            <input id={`tier-limit-${i}`} type="number" min={0} placeholder={i === tiers.length - 1 ? 'No limit' : ''} value={t.uptoPkr} onChange={(e) => patch(i, { uptoPkr: e.target.value })} className={control} />
          </div>
          <div className="col-span-4 space-y-1">
            <Label htmlFor={`tier-role-${i}`}>Approver</Label>
            <select id={`tier-role-${i}`} value={t.role} onChange={(e) => patch(i, { role: e.target.value })} className={control}>
              {ROLES.map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
          </div>
          <Button type="button" variant="ghost" size="sm" className="col-span-1" disabled={tiers.length === 1} onClick={() => setTiers(tiers.filter((_, idx) => idx !== i))}>
            Remove
          </Button>
        </div>
      ))}
      <div className="flex items-center gap-2">
        <Button type="button" variant="outline" size="sm" onClick={() => setTiers([...tiers, { uptoPkr: '', role: 'owner' }])}>
          Add tier
        </Button>
        <Button
          type="button"
          disabled={pending}
          data-testid="threshold-save"
          onClick={() =>
            startTransition(async () => {
              const r = await saveThresholdsAction({ tiers: tiers.map((t) => ({ uptoPkr: t.uptoPkr === '' ? '' : Number(t.uptoPkr), role: t.role as 'principal' })) });
              setError(r.error);
              if (!r.error) {
                toast.success('Thresholds saved.');
                router.refresh();
              }
            })
          }
        >
          Save thresholds
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="threshold-error">
          {error}
        </p>
      )}
    </div>
  );
}

export function ReceiptForm({ poId, stores, lines }: { poId: string; stores: Option[]; lines: { poLineId: string; description: string; shortfall: number }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [storeId, setStoreId] = useState(stores[0]?.value ?? '');
  const [qty, setQty] = useState<Record<string, string>>({});
  return (
    <div className="space-y-2" data-testid="receipt-form">
      <select aria-label="Store" value={storeId} onChange={(e) => setStoreId(e.target.value)} className={control}>
        {stores.map((s) => (
          <option key={s.value} value={s.value}>
            {s.label}
          </option>
        ))}
      </select>
      {lines
        .filter((l) => l.shortfall > 0)
        .map((l) => (
          <div key={l.poLineId} className="flex items-center justify-between gap-2 text-sm">
            <span>
              {l.description} <span className="text-muted-foreground">(still to come: {l.shortfall})</span>
            </span>
            <input aria-label={`Received ${l.description}`} type="number" min={0} step="any" value={qty[l.poLineId] ?? ''} onChange={(e) => setQty({ ...qty, [l.poLineId]: e.target.value })} className="h-8 w-24 rounded-md border bg-background px-2" />
          </div>
        ))}
      {error && (
        <p role="alert" className="text-sm text-destructive" data-testid="receipt-error">
          {error}
        </p>
      )}
      <Button
        disabled={pending}
        data-testid="receipt-submit"
        onClick={() =>
          startTransition(async () => {
            const r = await postGoodsReceiptAction({
              poId,
              storeId,
              lines: Object.entries(qty)
                .filter(([, v]) => Number(v) > 0)
                .map(([poLineId, v]) => ({ poLineId, qtyReceived: Number(v) })),
            });
            setError(r.error);
            if (!r.error) {
              toast.success('Goods receipt posted.');
              setQty({});
              router.refresh();
            }
          })
        }
      >
        Post goods receipt
      </Button>
    </div>
  );
}

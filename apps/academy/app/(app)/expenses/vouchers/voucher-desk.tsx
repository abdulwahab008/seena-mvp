'use client';

import { useActionState, useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { getExpenseAttachmentUrl, markExpenseVoucherPaid, submitExpenseVoucher, type SubmitVoucherState } from './actions';
import { ApprovalTrail } from '../approval-trail';
import {
  requiredApproverLabel,
  VOUCHER_STATUS_LABEL,
  type ApprovalRow,
  type VoucherFilters,
  type VoucherRow,
} from '@/lib/expenses/voucher-query';
import { formatPaisa } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';

// Radix's Select.Item rejects an empty-string value; '' is this page's
// "all" sentinel, mapped the same way every other filtered page here does.
const UI_ALL = '__all__';

type Head = { id: string; code: string; name_en: string; requires_approval: boolean };
type Campus = { id: string; code: string; name: string };

const INITIAL: SubmitVoucherState = { error: null };

const today = () => new Date().toISOString().slice(0, 10);

export function VoucherDesk({
  role,
  campuses,
  heads,
  filters,
  rows,
  approvals,
}: {
  role: string;
  campuses: Campus[];
  heads: Head[];
  filters: VoucherFilters;
  rows: VoucherRow[];
  approvals: ApprovalRow[];
}) {
  const router = useRouter();
  const formRef = useRef<HTMLFormElement>(null);
  const [state, action, submitting] = useActionState(submitExpenseVoucher, INITIAL);
  const [paying, startPaying] = useTransition();
  const [expanded, setExpanded] = useState<string | null>(null);
  const [payRefs, setPayRefs] = useState<Record<string, string>>({});

  const [campusId, setCampusId] = useState(campuses[0]?.id ?? '');
  const [headId, setHeadId] = useState(heads[0]?.id ?? '');

  const canPay = ['super_admin', 'owner', 'principal', 'accountant'].includes(role);

  useEffect(() => {
    if (state.error) {
      toast.error(state.error);
      return;
    }
    if (state.voucherId) {
      formRef.current?.reset();
      toast.success(
        state.status === 'approved'
          ? 'Submitted and self-approved — it is within the campus limit.'
          : `Submitted — it needs ${requiredApproverLabel(state.requiredApproverRole ?? null)} approval.`,
      );
      router.refresh();
    }
  }, [state, router]);

  const applyFilter = (next: Partial<{ campus: string; status: string }>) => {
    const params = new URLSearchParams();
    const campus = next.campus ?? filters.campusId;
    const status = next.status ?? filters.status;
    if (campus) params.set('campus', campus);
    if (status) params.set('status', status);
    router.push(`/expenses/vouchers${params.toString() ? `?${params.toString()}` : ''}`);
  };

  const pay = (voucherId: string) => {
    const fd = new FormData();
    fd.set('voucherId', voucherId);
    fd.set('paidReference', payRefs[voucherId] ?? '');
    startPaying(async () => {
      const result = await markExpenseVoucherPaid(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success('Recorded as paid.');
      router.refresh();
    });
  };

  // The tab is opened SYNCHRONOUSLY inside the click, then pointed at the
  // signed URL once it arrives: a window.open() that runs after an await is
  // outside the user gesture and every browser blocks it. opener is cleared
  // by hand because the 'noopener' feature makes window.open return null,
  // and we need the handle.
  const openBill = (path: string) => {
    const tab = window.open('', '_blank');
    if (tab) tab.opener = null;
    startPaying(async () => {
      const result = await getExpenseAttachmentUrl(path);
      if (result.error || !result.url) {
        tab?.close();
        toast.error(result.error ?? 'Could not open the bill.');
        return;
      }
      if (tab) tab.location.href = result.url;
      else window.open(result.url, '_blank', 'noopener');
    });
  };

  return (
    <div className="space-y-8">
      <section className="rounded-lg border p-4">
        <h2 className="mb-3 text-lg font-medium">Raise a voucher</h2>
        <form ref={formRef} action={action} className="grid gap-4 md:grid-cols-2">
          <input type="hidden" name="campusId" value={campusId} />
          <input type="hidden" name="headId" value={headId} />

          <div className="space-y-1">
            <Label>Campus</Label>
            <Select value={campusId} onValueChange={setCampusId}>
              <SelectTrigger data-testid="voucher-campus-trigger">
                <SelectValue placeholder="Choose a campus" />
              </SelectTrigger>
              <SelectContent>
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id} data-testid={`voucher-campus-option-${c.code}`}>
                    {c.name} ({c.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label>Expense head</Label>
            <Select value={headId} onValueChange={setHeadId}>
              <SelectTrigger data-testid="voucher-head-trigger">
                <SelectValue placeholder="Choose an expense head" />
              </SelectTrigger>
              <SelectContent>
                {heads.map((h) => (
                  <SelectItem key={h.id} value={h.id} data-testid={`voucher-head-option-${h.code}`}>
                    {h.name_en}
                    {h.requires_approval ? ' — always needs approval' : ''}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label htmlFor="payeeName">Paid to</Label>
            <Input id="payeeName" name="payeeName" required data-testid="voucher-payee-input" />
          </div>

          <div className="space-y-1">
            <Label htmlFor="payeeNtn">Payee NTN (optional)</Label>
            <Input id="payeeNtn" name="payeeNtn" data-testid="voucher-ntn-input" />
          </div>

          <div className="space-y-1">
            <Label htmlFor="amountRupees">Amount (PKR)</Label>
            <Input
              id="amountRupees"
              name="amountRupees"
              type="number"
              step="0.01"
              min="0.01"
              required
              data-testid="voucher-amount-input"
            />
          </div>

          <div className="space-y-1">
            <Label htmlFor="voucherDate">Voucher date</Label>
            <DatePicker
              id="voucherDate"
              name="voucherDate"
              defaultValue={today()}
              max={today()}
              required
              data-testid="voucher-date-input"
            />
          </div>

          <div className="space-y-1 md:col-span-2">
            <Label htmlFor="narrative">What it is for</Label>
            <Input id="narrative" name="narrative" data-testid="voucher-narrative-input" />
          </div>

          <div className="space-y-1 md:col-span-2">
            <Label htmlFor="attachment">Bill or invoice (JPEG, PNG or PDF, up to 5 MB)</Label>
            <Input
              id="attachment"
              name="attachment"
              type="file"
              accept="image/jpeg,image/png,application/pdf"
              data-testid="voucher-attachment-input"
            />
          </div>

          <div className="md:col-span-2">
            <Button type="submit" disabled={submitting} data-testid="voucher-submit-button">
              {submitting ? 'Submitting…' : 'Submit voucher'}
            </Button>
          </div>
        </form>

        {state.voucherId ? (
          <div className="mt-3 rounded border p-3 text-sm" data-testid="voucher-submit-result">
            {state.status === 'approved'
              ? 'Self-approved — within the campus self-approval limit.'
              : `Routed to ${requiredApproverLabel(state.requiredApproverRole ?? null)} for approval.`}
            {state.possibleThresholdSplit ? (
              <span data-testid="voucher-submit-split"> Flagged as a possible threshold split.</span>
            ) : null}
          </div>
        ) : null}
      </section>

      <section className="space-y-3">
        <div className="flex flex-wrap items-end gap-4">
          <div className="space-y-1">
            <Label>Campus</Label>
            <Select
              value={filters.campusId || UI_ALL}
              onValueChange={(v) => applyFilter({ campus: v === UI_ALL ? '' : v })}
            >
              <SelectTrigger className="w-56" data-testid="voucher-filter-campus-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={UI_ALL}>All campuses</SelectItem>
                {campuses.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name} ({c.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="space-y-1">
            <Label>Status</Label>
            <Select
              value={filters.status || UI_ALL}
              onValueChange={(v) => applyFilter({ status: v === UI_ALL ? '' : v })}
            >
              <SelectTrigger className="w-56" data-testid="voucher-filter-status-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={UI_ALL}>Every status</SelectItem>
                {Object.entries(VOUCHER_STATUS_LABEL).map(([value, label]) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="voucher-list-empty">
            No vouchers yet.
          </p>
        ) : (
          <ul className="space-y-3">
            {rows.map((v) => (
              <li key={v.id} className="rounded-lg border p-4" data-testid={`voucher-row-${v.id}`}>
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <div className="font-medium">
                    {v.payee_name} · PKR {formatPaisa(v.amount_paisa ?? 0)}
                  </div>
                  <div className="text-sm" data-testid={`voucher-status-${v.id}`}>
                    {VOUCHER_STATUS_LABEL[v.status ?? 'pending_approval']}
                  </div>
                </div>
                <div className="mt-1 text-sm text-muted-foreground">
                  {v.head_name} · {v.voucher_date} · {v.campus_name} ({v.campus_code})
                  {v.narrative ? ` · ${v.narrative}` : ''}
                </div>
                <div className="mt-1 text-sm" data-testid={`voucher-required-${v.id}`}>
                  Requires: {requiredApproverLabel(v.required_approver_role)}
                </div>
                {v.possible_threshold_split ? (
                  <div className="mt-1 text-sm font-medium" data-testid={`voucher-split-${v.id}`}>
                    Possible threshold split — {v.split_sibling_count} other voucher
                    {v.split_sibling_count === 1 ? '' : 's'} for this payee, head and date, PKR{' '}
                    {formatPaisa(v.split_group_total_paisa ?? 0)} in total.
                  </div>
                ) : null}
                {v.paid_at ? (
                  <div className="mt-1 text-sm text-muted-foreground">
                    Paid {new Date(v.paid_at).toLocaleString('en-PK')}
                    {v.paid_by_name ? ` by ${v.paid_by_name}` : ''}
                    {v.paid_reference ? ` · ${v.paid_reference}` : ''}
                  </div>
                ) : null}

                <div className="mt-3 flex flex-wrap gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => setExpanded(expanded === v.id ? null : v.id)}
                    data-testid={`voucher-history-toggle-${v.id}`}
                  >
                    {expanded === v.id ? 'Hide approval history' : 'Approval history'}
                  </Button>
                  {v.attachment_path ? (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => openBill(v.attachment_path!)}
                      data-testid={`voucher-bill-${v.id}`}
                    >
                      Open bill
                    </Button>
                  ) : null}
                  {canPay && v.status === 'approved' ? (
                    <>
                      <Input
                        className="w-48"
                        placeholder="Cheque or transfer ref"
                        value={payRefs[v.id!] ?? ''}
                        onChange={(e) => setPayRefs((prev) => ({ ...prev, [v.id!]: e.target.value }))}
                        data-testid={`voucher-pay-reference-${v.id}`}
                      />
                      <Button type="button" size="sm" disabled={paying} onClick={() => pay(v.id!)} data-testid={`voucher-pay-${v.id}`}>
                        Mark paid
                      </Button>
                    </>
                  ) : null}
                  {/* AC1/AC2: an unapproved or rejected voucher offers no pay
                      button, and the database refuses one regardless. */}
                  {v.status === 'pending_approval' ? (
                    <span className="self-center text-xs text-muted-foreground" data-testid={`voucher-unpayable-${v.id}`}>
                      Cannot be paid until {requiredApproverLabel(v.required_approver_role)} approves.
                    </span>
                  ) : null}
                  {v.status === 'rejected' ? (
                    <span className="self-center text-xs text-muted-foreground" data-testid={`voucher-locked-${v.id}`}>
                      Rejected and locked — correct it by submitting a new voucher.
                    </span>
                  ) : null}
                </div>

                {expanded === v.id ? (
                  <div className="mt-3">
                    <ApprovalTrail approvals={approvals} voucherId={v.id!} />
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

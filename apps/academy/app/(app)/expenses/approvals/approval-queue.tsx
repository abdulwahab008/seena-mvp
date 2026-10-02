'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { decideExpenseVoucher } from './actions';
import { ApprovalTrail } from '../approval-trail';
import {
  canDecide,
  requiredApproverLabel,
  type ApprovalRow,
  type VoucherFilters,
  type VoucherRow,
} from '@/lib/expenses/voucher-query';
import { formatPaisa } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

const UI_ALL = '__all__';

// AC2's bar, mirrored from chk_expense_approval_reason. The button is
// disabled below it; the database refuses below it regardless.
const MIN_REASON = 10;

export function ApprovalQueue({
  role,
  campuses,
  filters,
  rows,
  approvals,
}: {
  role: string;
  campuses: Array<{ id: string; code: string; name: string }>;
  filters: VoucherFilters;
  rows: VoucherRow[];
  approvals: ApprovalRow[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [expanded, setExpanded] = useState<string | null>(null);

  const decide = (voucherId: string, decision: 'approved' | 'rejected') => {
    const fd = new FormData();
    fd.set('voucherId', voucherId);
    fd.set('decision', decision);
    fd.set('reason', reasons[voucherId] ?? '');
    startTransition(async () => {
      const result = await decideExpenseVoucher(fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success(decision === 'approved' ? 'Approved — it can now be paid.' : 'Rejected and locked.');
      setReasons((prev) => ({ ...prev, [voucherId]: '' }));
      router.refresh();
    });
  };

  return (
    <div className="space-y-4">
      <div className="space-y-1">
        <Label>Campus</Label>
        <Select
          value={filters.campusId || UI_ALL}
          onValueChange={(v) => router.push(v === UI_ALL ? '/expenses/approvals' : `/expenses/approvals?campus=${v}`)}
        >
          <SelectTrigger className="w-56" data-testid="approvals-campus-trigger">
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

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="approvals-empty">
          Nothing is waiting for approval.
        </p>
      ) : (
        <ul className="space-y-3">
          {rows.map((v) => {
            const mine = canDecide(role, v.required_approver_role);
            const reason = reasons[v.id!] ?? '';
            return (
              <li key={v.id} className="rounded-lg border p-4" data-testid={`approval-row-${v.id}`}>
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <div className="font-medium">
                    {v.payee_name} · PKR {formatPaisa(v.amount_paisa ?? 0)}
                  </div>
                  <div className="text-sm" data-testid={`approval-required-${v.id}`}>
                    Requires: {requiredApproverLabel(v.required_approver_role)}
                  </div>
                </div>
                <div className="mt-1 text-sm text-muted-foreground">
                  {v.head_name} · {v.voucher_date} · {v.campus_name} ({v.campus_code})
                  {v.submitted_by_name ? ` · raised by ${v.submitted_by_name}` : ''}
                  {v.narrative ? ` · ${v.narrative}` : ''}
                </div>

                {v.possible_threshold_split ? (
                  <div className="mt-2 rounded border p-2 text-sm font-medium" data-testid={`approval-split-${v.id}`}>
                    Possible threshold split: {v.split_sibling_count} other voucher
                    {v.split_sibling_count === 1 ? '' : 's'} for the same payee, head and date, PKR{' '}
                    {formatPaisa(v.split_group_total_paisa ?? 0)} in total. Each is below the self-approval limit on its own.
                  </div>
                ) : null}

                <div className="mt-3 space-y-2">
                  <Label htmlFor={`reason-${v.id}`}>Reason (required to reject, at least {MIN_REASON} characters)</Label>
                  <Input
                    id={`reason-${v.id}`}
                    value={reason}
                    onChange={(e) => setReasons((prev) => ({ ...prev, [v.id!]: e.target.value }))}
                    disabled={!mine}
                    data-testid={`approval-reason-${v.id}`}
                  />
                </div>

                <div className="mt-3 flex flex-wrap gap-2">
                  {mine ? (
                    <>
                      <Button
                        type="button"
                        size="sm"
                        disabled={pending}
                        onClick={() => decide(v.id!, 'approved')}
                        data-testid={`approval-approve-${v.id}`}
                      >
                        Approve
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={pending || reason.trim().length < MIN_REASON}
                        onClick={() => decide(v.id!, 'rejected')}
                        data-testid={`approval-reject-${v.id}`}
                      >
                        Reject
                      </Button>
                      {reason.trim().length > 0 && reason.trim().length < MIN_REASON ? (
                        <span className="self-center text-xs text-muted-foreground" data-testid={`approval-reason-short-${v.id}`}>
                          A rejection has to say why, in at least {MIN_REASON} characters.
                        </span>
                      ) : null}
                    </>
                  ) : (
                    <span className="self-center text-xs text-muted-foreground" data-testid={`approval-above-limit-${v.id}`}>
                      Above your approval limit — this one is {requiredApproverLabel(v.required_approver_role)}&apos;s.
                    </span>
                  )}
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => setExpanded(expanded === v.id ? null : v.id)}
                    data-testid={`approval-history-toggle-${v.id}`}
                  >
                    {expanded === v.id ? 'Hide approval history' : 'Approval history'}
                  </Button>
                </div>

                {expanded === v.id ? (
                  <div className="mt-3">
                    <ApprovalTrail approvals={approvals} voucherId={v.id!} />
                  </div>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

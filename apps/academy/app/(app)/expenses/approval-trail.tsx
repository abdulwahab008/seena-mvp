'use client';

import { APPROVER_ROLE_LABEL, type ApprovalRow } from '@/lib/expenses/voucher-query';

const DECISION_LABEL: Record<string, string> = {
  approved: 'Approved',
  rejected: 'Rejected',
  escalated: 'Re-opened for approval',
};

/**
 * FR-L11 AC4. The trail is append-only in the database — no role can update
 * or delete a row of it — so this renders every decision in the order it was
 * made, including the automatic re-openings, and offers no way to edit one.
 *
 * request_ip is labelled "reported" on purpose: it is the address the
 * request said it came from, which is evidence behind a trusted proxy and a
 * claim otherwise (see lib/request-ip.ts). Calling it anything stronger on
 * screen would overstate what the column holds.
 */
export function ApprovalTrail({ approvals, voucherId }: { approvals: ApprovalRow[]; voucherId: string }) {
  const rows = approvals.filter((a) => a.voucher_id === voucherId);

  if (rows.length === 0) {
    return (
      <p className="text-xs text-muted-foreground" data-testid={`trail-empty-${voucherId}`}>
        Nothing decided yet.
      </p>
    );
  }

  return (
    <ol className="space-y-2 text-xs" data-testid={`trail-${voucherId}`}>
      {rows.map((a) => (
        <li key={a.id} className="rounded border p-2">
          <div className="font-medium">
            {DECISION_LABEL[a.decision ?? ''] ?? a.decision}
            {a.approver_name ? ` — ${a.approver_name}` : ' — automatic'}
            {a.approver_role ? ` (${APPROVER_ROLE_LABEL[a.approver_role] ?? a.approver_role})` : ''}
          </div>
          <div className="text-muted-foreground">
            {a.decided_at ? new Date(a.decided_at).toLocaleString('en-PK') : ''}
            {' · IP reported: '}
            <span data-testid={`trail-ip-${a.id}`}>{a.request_ip ?? 'not recorded'}</span>
          </div>
          {a.reason ? <div className="mt-1">{a.reason}</div> : null}
        </li>
      ))}
    </ol>
  );
}

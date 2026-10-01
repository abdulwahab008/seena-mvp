import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { pkr } from '@/lib/rpc-action';
import { loose } from '@/lib/transport/rpc';
import { RequisitionForm, ThresholdForm } from './purchasing-forms';

type Tier = { level: number; upto_amount: number | null; approver_role: string };
const ROLE_LABEL: Record<string, string> = { principal: 'Principal', vice_principal: 'Vice Principal', accountant: 'Accountant', hr_manager: 'HR Manager', owner: 'Director' };

export default async function PurchasingPage() {
  const supabase = await supabaseServer();
  const [reqs, queue, campuses, departments, items, tiers, me] = await Promise.all([
    supabase.from('purchase_requisition').select('id, req_no, est_total, status, current_level, approval_chain, raised_at, justification').order('raised_at', { ascending: false }).limit(60),
    supabase.from('v_requisition_approval_queue').select('req_id, req_no, est_total, justification, awaiting_role'),
    supabase.from('campus').select('id, name').order('name'),
    supabase.from('department').select('id, name_en').order('name_en'),
    // a requester (a head of department, a teacher) cannot read inv_item itself, so the picker reads code + name through a definer function
    loose(supabase).rpc('list_requisition_items'),
    supabase.from('purchase_threshold').select('level, upto_amount, approver_role, effective_from, campus_id').is('campus_id', null).order('effective_from', { ascending: false }).order('level'),
    supabase.auth.getUser(),
  ]);
  const latest = (tiers.data ?? []).filter((t) => t.effective_from === (tiers.data ?? [])[0]?.effective_from) as unknown as Tier[];
  void me;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Purchase requisitions"
        description="FR-R06 — raise a requisition; it routes to the approvers set by the school's spending thresholds, in order. The route is fixed when you submit. Editing after an approval cancels every approval and starts again."
      />

      {(queue.data ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Waiting for your approval</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm" data-testid="approval-queue">
            {(queue.data ?? []).map((q) => (
              <div key={q.req_id} className="flex items-center justify-between border-b py-2" data-testid="queue-row">
                <span>
                  <span className="font-mono">{q.req_no}</span> · {pkr(q.est_total)} · {q.justification}
                </span>
                <Link href={`/purchasing/${q.req_id}`} className="underline">
                  Review
                </Link>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Requisitions</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="requisition-list">
          {(reqs.data ?? []).length === 0 && <p className="text-muted-foreground">No requisitions yet.</p>}
          {(reqs.data ?? []).map((r) => {
            const chain = (r.approval_chain as { level: number; approver_role: string }[]) ?? [];
            return (
              <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b py-2" data-testid="requisition-row">
                <span>
                  <Link href={`/purchasing/${r.id}`} className="font-mono underline">
                    {r.req_no}
                  </Link>{' '}
                  · {pkr(r.est_total)} · {r.justification}
                </span>
                <span className="flex items-center gap-2">
                  {r.status === 'pending' && chain.length > 0 && <span className="text-muted-foreground">awaiting {ROLE_LABEL[chain[r.current_level - 1]?.approver_role ?? ''] ?? '—'}</span>}
                  <Badge variant={r.status === 'approved' || r.status === 'converted' ? 'success' : 'outline'}>{r.status}</Badge>
                </span>
              </div>
            );
          })}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Raise a requisition</CardTitle>
          </CardHeader>
          <CardContent>
            <RequisitionForm
              campuses={(campuses.data ?? []).map((c) => ({ value: c.id, label: c.name }))}
              departments={(departments.data ?? []).map((d) => ({ value: d.id, label: d.name_en }))}
              items={((items.data ?? []) as { id: string; item_code: string; name: string }[]).map((i) => ({ value: i.id, label: `${i.item_code} · ${i.name}`, name: i.name }))}
            />
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Approval thresholds</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <p className="text-sm text-muted-foreground">Each tier approves up to its limit; anything above goes on to the next tier as well. Only the Owner can change these, and changes never re-route a requisition already submitted.</p>
            <ThresholdForm initial={latest.map((t) => ({ uptoPkr: t.upto_amount == null ? '' : String(Number(t.upto_amount) / 100), role: t.approver_role }))} />
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

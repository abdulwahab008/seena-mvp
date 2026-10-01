import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { ActionForm } from '@/components/action-form';
import { pkr } from '@/lib/rpc-action';
import { convertToPoAction } from '../actions';
import { DecisionButtons, RequisitionForm, SubmitButton } from '../purchasing-forms';

const ROLE_LABEL: Record<string, string> = { principal: 'Principal', vice_principal: 'Vice Principal', accountant: 'Accountant', hr_manager: 'HR Manager', owner: 'Director' };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function RequisitionPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: req } = await supabase
    .from('purchase_requisition')
    .select('id, req_no, campus_id, department_id, justification, est_total, status, current_level, version, approval_chain, raised_by')
    .eq('id', id)
    .maybeSingle();
  if (!req) notFound();
  const [lines, approvals, queue, user, campuses, departments, items, vendors] = await Promise.all([
    supabase.from('purchase_requisition_line').select('id, item_id, description, qty, est_unit_cost').eq('req_id', id).order('description'),
    supabase.from('purchase_approval').select('id, level, approver_role, decision, remarks, decided_at, voided_at, void_reason, approver:approved_by(full_name)').eq('req_id', id).order('decided_at'),
    supabase.from('v_requisition_approval_queue').select('req_id').eq('req_id', id),
    supabase.auth.getUser(),
    supabase.from('campus').select('id, name').order('name'),
    supabase.from('department').select('id, name_en').order('name_en'),
    supabase.from('inv_item').select('id, item_code, name').eq('active', true).order('item_code'),
    supabase.from('procurement_vendor').select('id, name').eq('active', true).order('name'),
  ]);
  const chain = (req.approval_chain as { level: number; approver_role: string }[]) ?? [];
  const mine = user.data.user?.id === req.raised_by;
  const awaitingMe = (queue.data ?? []).length > 0;
  const editable = req.status === 'draft' || req.status === 'pending';

  return (
    <div className="space-y-6">
      <PageHeader title={`${req.req_no} · ${pkr(req.est_total)}`} description={req.justification} />

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center justify-between text-base">
            <span>Approval route</span>
            <Badge data-testid="req-status" variant={req.status === 'approved' || req.status === 'converted' ? 'success' : 'outline'}>
              {req.status}
            </Badge>
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          {chain.length === 0 ? (
            <p className="text-muted-foreground">The route is fixed when the requisition is submitted.</p>
          ) : (
            <ol className="list-decimal space-y-1 pl-5" data-testid="approval-chain">
              {chain.map((c) => {
                const done = (approvals.data ?? []).find((a) => a.level === c.level && !a.voided_at && a.decision === 'approve');
                return (
                  <li key={c.level}>
                    {ROLE_LABEL[c.approver_role] ?? c.approver_role}
                    {done ? ` — approved by ${one(done.approver)?.full_name ?? 'approver'}` : req.status === 'pending' && c.level === req.current_level ? ' — awaiting' : ''}
                  </li>
                );
              })}
            </ol>
          )}
          {req.status === 'draft' && mine && <SubmitButton reqId={req.id} />}
          {awaitingMe && <DecisionButtons reqId={req.id} />}
          {req.status === 'approved' && (
            <ActionForm
              testId="po-form"
              submitLabel="Convert to purchase order"
              action={convertToPoAction}
              fields={[
                { name: 'reqId', label: 'Requisition', type: 'hidden', defaultValue: req.id },
                { name: 'vendorId', label: 'Vendor', type: 'select', required: true, options: (vendors.data ?? []).map((v) => ({ value: v.id, label: v.name })) },
              ]}
            />
          )}
          {(approvals.data ?? []).some((a) => a.voided_at) && (
            <div className="text-muted-foreground" data-testid="voided-approvals">
              {(approvals.data ?? []).filter((a) => a.voided_at).map((a) => (
                <p key={a.id}>
                  Voided: {ROLE_LABEL[a.approver_role] ?? a.approver_role} approval ({a.void_reason}).
                </p>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Items</CardTitle>
        </CardHeader>
        <CardContent className="text-sm">
          {(lines.data ?? []).map((l) => (
            <p key={l.id} data-testid="req-detail-line">
              {l.description} · {Number(l.qty)} × {pkr(l.est_unit_cost)}
            </p>
          ))}
        </CardContent>
      </Card>

      {editable && mine && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Edit</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {req.status === 'pending' && (approvals.data ?? []).some((a) => !a.voided_at) && (
              <p className="text-sm text-destructive" data-testid="edit-warning">
                This requisition already has an approval. Saving a change cancels every approval and restarts the route from the first approver.
              </p>
            )}
            <RequisitionForm
              reqId={req.id}
              campuses={(campuses.data ?? []).map((c) => ({ value: c.id, label: c.name }))}
              departments={(departments.data ?? []).map((d) => ({ value: d.id, label: d.name_en }))}
              items={(items.data ?? []).map((i) => ({ value: i.id, label: `${i.item_code} · ${i.name}`, name: i.name }))}
              initial={{
                campusId: req.campus_id,
                departmentId: req.department_id ?? '',
                justification: req.justification,
                lines: (lines.data ?? []).map((l) => ({ itemId: l.item_id ?? '', description: l.description, qty: String(Number(l.qty)), estUnitCostPkr: String(Number(l.est_unit_cost) / 100) })),
              }}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

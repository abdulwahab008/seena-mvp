import { supabaseServer } from '@/lib/supabase/server';
import { CreateFeeHeadForm } from './create-fee-head-form';
import { FeeHeadList } from './fee-head-list';

export default async function FeeHeadsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: appUser }, { data: feeHeads }, { data: priorities }] = await Promise.all([
    supabase.from('app_user').select('tenant_id').eq('user_id', user!.id).single(),
    supabase.from('fee_head').select('id, code, name_en, name_ur, is_refundable, default_frequency, is_active, withdrawal_treatment').order('code'),
    supabase.from('fee_head_priority').select('fee_head_id, priority'),
  ]);
  const priorityOf = new Map((priorities ?? []).map((p) => [p.fee_head_id, p.priority]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee heads</h1>
        <p className="text-sm text-muted-foreground">The catalogue every fee structure and ledger entry is built on. A part payment clears heads in payment order (lowest first); on leaving, a prorated head is charged only for the days attended.</p>
      </div>
      <CreateFeeHeadForm />
      <FeeHeadList tenantId={appUser!.tenant_id} feeHeads={(feeHeads ?? []).map((h) => ({ ...h, priority: priorityOf.get(h.id) ?? null }))} />
    </div>
  );
}

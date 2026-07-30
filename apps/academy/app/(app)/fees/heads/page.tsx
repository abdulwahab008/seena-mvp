import { supabaseServer } from '@/lib/supabase/server';
import { CreateFeeHeadForm } from './create-fee-head-form';
import { FeeHeadList } from './fee-head-list';

export default async function FeeHeadsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const [{ data: appUser }, { data: feeHeads }] = await Promise.all([
    supabase.from('app_user').select('tenant_id').eq('user_id', user!.id).single(),
    supabase.from('fee_head').select('id, code, name_en, name_ur, is_refundable, default_frequency, is_active').order('code'),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Fee heads</h1>
        <p className="text-sm text-muted-foreground">FR-K01 — the catalogue every fee structure and ledger entry is built on.</p>
      </div>
      <CreateFeeHeadForm />
      <FeeHeadList tenantId={appUser!.tenant_id} feeHeads={feeHeads ?? []} />
    </div>
  );
}

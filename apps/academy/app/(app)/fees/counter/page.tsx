import { supabaseServer } from '@/lib/supabase/server';
import { CounterView } from './counter-view';

export default async function CashCounterPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role;
  const canCollect = role === 'super_admin' || role === 'owner' || role === 'accountant';

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Cash counter</h1>
        <p className="text-sm text-muted-foreground">
          FR-K17 — scan a challan, collect a payment, and print a receipt with a gapless number and amount in words.
        </p>
      </div>
      {canCollect ? (
        <CounterView />
      ) : (
        <p className="text-sm text-muted-foreground">Only an Accountant, Owner, or Super Admin can use the cash counter.</p>
      )}
    </div>
  );
}

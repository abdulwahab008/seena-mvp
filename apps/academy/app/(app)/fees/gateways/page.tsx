import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { GatewayForm } from './gateway-form';

export default async function PaymentGatewaysPage() {
  const supabase = await supabaseServer();
  const [cfgRes, alertRes] = await Promise.all([
    supabase.from('payment_gateway_config').select('id, gateway, merchant_id, is_live, is_enabled, secret_ref').order('gateway'),
    supabase
      .from('payment_alert')
      .select('id, kind, expected_paisa, received_paisa, detail, created_at, resolved_at')
      .is('resolved_at', null)
      .order('created_at', { ascending: false })
      .limit(50),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Online payments</h1>
        <p className="text-sm text-muted-foreground">
          FR-K21/K22 — gateways parents can pay with, and payment callbacks that need a human look.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Configured gateways</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm">
          {(cfgRes.data ?? []).length === 0 && <p className="text-muted-foreground">None yet. Parents will see the printable challan only.</p>}
          {(cfgRes.data ?? []).map((g) => (
            <div key={g.id} className="flex justify-between border-b py-1" data-testid="gateway-row">
              <span>
                {g.gateway} · merchant {g.merchant_id} · {g.is_live ? 'live' : 'sandbox'}
              </span>
              <span className="text-muted-foreground">{g.is_enabled ? 'enabled' : 'disabled'} · secret in ${g.secret_ref}</span>
            </div>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Add or update a gateway</CardTitle>
        </CardHeader>
        <CardContent>
          <GatewayForm />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Payment alerts ({alertRes.data?.length ?? 0})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm">
          {(alertRes.data ?? []).length === 0 && <p className="text-muted-foreground">No open alerts.</p>}
          {(alertRes.data ?? []).map((a) => (
            <div key={a.id} className="flex justify-between border-b py-1" data-testid="payment-alert">
              <span>
                {a.kind.replace('_', ' ')} — expected {((a.expected_paisa ?? 0) / 100).toLocaleString()} PKR, received {((a.received_paisa ?? 0) / 100).toLocaleString()} PKR
              </span>
              <span className="text-muted-foreground">{new Date(a.created_at).toLocaleString()}</span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

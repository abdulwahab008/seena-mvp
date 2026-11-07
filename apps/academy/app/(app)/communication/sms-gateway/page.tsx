import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { PageHeader } from '@/components/ui/page-header';
import { GatewayForm } from './gateway-form';

export const dynamic = 'force-dynamic';

export default async function SmsGatewayPage() {
  const actor = await getCurrentActor();
  if (!actor || !['super_admin', 'owner'].includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('sms_gateway_settings').maybeSingle();
  const config = (data?.config ?? {}) as Record<string, string>;

  return (
    <>
      <PageHeader
        title="SMS gateway"
        description="Connect your SMS provider so attendance alerts, fee reminders and circulars actually go out. Your provider's API documentation lists the URL and parameter names. The API key is stored encrypted and never shown again."
      />
      <GatewayForm
        hasKey={data?.has_key ?? false}
        defaults={{
          url: config.url ?? '',
          method: config.method === 'POST' ? 'POST' : 'GET',
          keyParam: config.keyParam ?? 'api_key',
          senderParam: config.senderParam ?? 'sender',
          toParam: config.toParam ?? 'to',
          textParam: config.textParam ?? 'message',
          successMatch: config.successMatch ?? '',
          numberFormat: config.numberFormat === 'local' ? 'local' : 'intl',
          senderId: data?.sender_id ?? '',
          apiKey: '',
        }}
      />
    </>
  );
}

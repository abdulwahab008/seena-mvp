'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { saveGateway, sendTestSms } from './actions';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const schema = z.object({
  url: z.string().trim().min(1, 'Enter the gateway URL'),
  method: z.enum(['GET', 'POST']),
  keyParam: z.string().min(1),
  senderParam: z.string().min(1),
  toParam: z.string().min(1),
  textParam: z.string().min(1),
  successMatch: z.string(),
  numberFormat: z.enum(['intl', 'local']),
  senderId: z.string().trim().min(1, 'Enter the sender mask'),
  apiKey: z.string(),
});
type Values = z.infer<typeof schema>;
const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function GatewayForm({ defaults, hasKey }: { defaults: Values; hasKey: boolean }) {
  const [pending, startTransition] = useTransition();
  const [saved, setSaved] = useState(hasKey);
  const test = useForm<{ to: string }>({ resolver: zodResolver(z.object({ to: z.string().trim().min(10, 'Enter your mobile number') })), defaultValues: { to: '' } });
  const { register, handleSubmit, setValue, formState: { errors } } = useForm<Values>({ resolver: zodResolver(schema), defaultValues: defaults });

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveGateway(v);
      if (r.error) return void toast.error(r.error);
      toast.success('SMS gateway saved.');
      setSaved(true);
      setValue('apiKey', '');
    }),
  );
  const field = (id: keyof Values, label: string, hint?: string) => (
    <div className="space-y-1">
      <Label htmlFor={`gw-${id}`}>{label}</Label>
      <Input id={`gw-${id}`} {...register(id)} />
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      {errors[id] && <p className="text-sm text-destructive">{errors[id]?.message}</p>}
    </div>
  );

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_20rem]">
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Gateway {saved && <Badge variant="success">connected</Badge>}</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2" noValidate>
            <div className="sm:col-span-2">{field('url', 'Send URL', 'e.g. https://api.yourprovider.pk/sendsms')}</div>
            <div className="space-y-1">
              <Label htmlFor="gw-method">Method</Label>
              <select id="gw-method" className={SELECT} {...register('method')}>
                <option value="GET">GET (parameters in the URL)</option>
                <option value="POST">POST (form fields)</option>
              </select>
            </div>
            <div className="space-y-1">
              <Label htmlFor="gw-numberFormat">Number format</Label>
              <select id="gw-numberFormat" className={SELECT} {...register('numberFormat')}>
                <option value="intl">923001234567</option>
                <option value="local">03001234567</option>
              </select>
            </div>
            {field('keyParam', 'API key parameter name')}
            {field('senderParam', 'Sender parameter name')}
            {field('toParam', 'Mobile number parameter name')}
            {field('textParam', 'Message parameter name')}
            {field('senderId', 'Sender mask', 'The approved name your messages come from')}
            {field('successMatch', 'Success reply contains (optional)', 'e.g. OK; leave blank to accept any 200 reply')}
            <div className="space-y-1 sm:col-span-2">
              <Label htmlFor="gw-apiKey">API key</Label>
              <Input id="gw-apiKey" type="password" autoComplete="off" placeholder={saved ? 'Saved. Enter a new key only to replace it.' : ''} {...register('apiKey')} />
            </div>
            <Button type="submit" disabled={pending} className="sm:w-fit">
              Save gateway
            </Button>
          </form>
        </CardContent>
      </Card>
      <Card className="h-fit">
        <CardHeader>
          <CardTitle className="text-base">Send a test</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="space-y-2"
            noValidate
            onSubmit={test.handleSubmit(({ to }) =>
              startTransition(async () => {
                const r = await sendTestSms(to);
                if (r.error) toast.error(r.error);
                else toast.success('Test SMS sent. Check your phone.');
              }),
            )}
          >
            <Label htmlFor="gw-test">Your mobile number</Label>
            <Input id="gw-test" placeholder="03001234567" {...test.register('to')} />
            {test.formState.errors.to && <p className="text-sm text-destructive">{test.formState.errors.to.message}</p>}
            <Button type="submit" variant="outline" disabled={pending || !saved}>
              Send test SMS
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}

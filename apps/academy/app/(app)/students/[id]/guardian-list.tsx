'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { sendGuardianPortalInvite } from '../actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type GuardianLink = {
  guardian_id: string;
  relationship: string;
  is_primary: boolean;
  receives_billing: boolean;
  may_collect_child: boolean;
  guardian:
    | { name_en: string; phone_e164: string | null; cnic: string | null; auth_user_id: string | null }
    | { name_en: string; phone_e164: string | null; cnic: string | null; auth_user_id: string | null }[];
};

type Channel = 'whatsapp' | 'sms' | 'print';

function InvitePanel({ guardianId, phone }: { guardianId: string; phone: string | null }) {
  const [channel, setChannel] = useState<Channel>('whatsapp');
  const [link, setLink] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const onSend = () => {
    startTransition(async () => {
      const result = await sendGuardianPortalInvite(guardianId, channel, { error: null, result: null }, new FormData());
      if (result.error) {
        toast.error(result.error);
        return;
      }
      const url = `${window.location.origin}/guardian/activate/${result.result!.token}`;
      if (channel === 'print') {
        setLink(url);
      } else {
        setLink(null);
        toast.success(`Invite sent via ${channel}.`);
      }
    });
  };

  return (
    <div className="space-y-2 border-t pt-2">
      <div className="flex flex-wrap items-center gap-2">
        <Select value={channel} onValueChange={(v) => setChannel(v as Channel)}>
          <SelectTrigger data-testid={`guardian-invite-channel-${guardianId}`} className="w-32">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="whatsapp">WhatsApp</SelectItem>
            <SelectItem value="sms">SMS</SelectItem>
            <SelectItem value="print">Print slip</SelectItem>
          </SelectContent>
        </Select>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={pending || !phone}
          onClick={onSend}
          data-testid={`guardian-invite-send-${guardianId}`}
        >
          {pending ? 'Sending…' : 'Send portal invite'}
        </Button>
        {!phone && <p className="text-xs text-destructive">No phone on file.</p>}
      </div>
      {link && (
        <p className="break-all rounded border bg-muted p-2 text-xs" data-testid={`guardian-invite-link-${guardianId}`}>
          {link}
        </p>
      )}
    </div>
  );
}

export function GuardianList({ links }: { links: GuardianLink[] }) {
  if (links.length === 0) {
    return <p className="text-sm text-muted-foreground">No guardians linked yet.</p>;
  }

  return (
    <div className="space-y-2">
      {links.map((l) => {
        const guardian = Array.isArray(l.guardian) ? l.guardian[0] : l.guardian;
        if (!guardian) return null;
        const flags = [
          l.is_primary && 'primary',
          l.receives_billing && 'billing',
          l.may_collect_child ? 'may collect' : 'may NOT collect',
        ].filter(Boolean);

        return (
          <Card key={l.guardian_id} data-testid={`guardian-row-${guardian.name_en}`}>
            <CardContent className="space-y-2 p-4">
              <div className="flex items-center justify-between">
                <div>
                  <p className="font-medium">
                    {guardian.name_en} <span className="text-muted-foreground">({l.relationship})</span>
                  </p>
                  <p className="text-sm text-muted-foreground">
                    {guardian.phone_e164 ?? 'no phone'} · {flags.join(', ')}
                  </p>
                </div>
                {guardian.auth_user_id && (
                  <span className="rounded-full border px-2 py-0.5 text-xs text-muted-foreground">portal active</span>
                )}
              </div>
              {!guardian.auth_user_id && <InvitePanel guardianId={l.guardian_id} phone={guardian.phone_e164} />}
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}

'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { sendGuardianPortalInvite, setGuardianProfession } from '../actions';
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
    | GuardianSummary
    | GuardianSummary[];
};

type GuardianSummary = { name_en: string; phone_e164: string | null; cnic: string | null; auth_user_id: string | null; profession_id: string | null };
type Option = { id: string; label: string };

function ProfessionSelect({ guardianId, value, options }: { guardianId: string; value: string | null; options: Option[] }) {
  const [pending, startTransition] = useTransition();
  return (
    <select
      aria-label="Profession"
      defaultValue={value ?? ''}
      disabled={pending}
      data-testid={`guardian-profession-${guardianId}`}
      className="h-8 rounded-md border bg-background px-2 text-sm"
      onChange={(e) => {
        const next = e.target.value;
        startTransition(async () => {
          const r = await setGuardianProfession(guardianId, next || null);
          if (r.error) toast.error(r.error);
          else toast.success('Profession saved.');
        });
      }}
    >
      <option value="">Profession not set</option>
      {options.map((o) => (
        <option key={o.id} value={o.id}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

type Channel = 'whatsapp' | 'sms' | 'print';

function InvitePanel({ guardianId, phone }: { guardianId: string; phone: string | null }) {
  const [channel, setChannel] = useState<Channel>('whatsapp');
  const [link, setLink] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const onSend = () => {
    startTransition(async () => {
      const result = await sendGuardianPortalInvite(guardianId, channel, { error: null, result: null }, new FormData());
      if (result.error) {
        toast.error(result.error);
        return;
      }
      const r = result.result!;
      setLink(r.link);
      if (channel === 'print') setNote('Print or hand this link to the parent. It works once and expires in 72 hours.');
      else if (r.queued) {
        setNote(`Queued for ${channel === 'sms' ? 'SMS' : 'WhatsApp'} in the message outbox. It goes out when the messaging provider sends the queue. You can also share the link yourself.`);
        toast.success(`Invite queued for ${channel === 'sms' ? 'SMS' : 'WhatsApp'}.`);
      } else setNote('No message could be queued for this guardian. Share this link with the parent yourself.');
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
        <div className="space-y-1" data-testid={`guardian-invite-result-${guardianId}`}>
          {note && <p className="text-xs text-muted-foreground">{note}</p>}
          <p className="select-all break-all rounded border bg-muted p-2 text-xs" data-testid={`guardian-invite-link-${guardianId}`}>
            {link}
          </p>
        </div>
      )}
    </div>
  );
}

export function GuardianList({ links, professions, canEditProfession }: { links: GuardianLink[]; professions: Option[]; canEditProfession: boolean }) {
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
                    {!canEditProfession && guardian.profession_id && ` · ${professions.find((p) => p.id === guardian.profession_id)?.label ?? ''}`}
                  </p>
                  {canEditProfession && professions.length > 0 && (
                    <ProfessionSelect guardianId={l.guardian_id} value={guardian.profession_id} options={professions} />
                  )}
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

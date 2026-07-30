import { Card, CardContent } from '@/components/ui/card';

export type GuardianLink = {
  guardian_id: string;
  relationship: string;
  is_primary: boolean;
  receives_billing: boolean;
  may_collect_child: boolean;
  guardian: { name_en: string; phone_e164: string | null; cnic: string | null } | { name_en: string; phone_e164: string | null; cnic: string | null }[];
};

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
            <CardContent className="flex items-center justify-between p-4">
              <div>
                <p className="font-medium">
                  {guardian.name_en} <span className="text-muted-foreground">({l.relationship})</span>
                </p>
                <p className="text-sm text-muted-foreground">
                  {guardian.phone_e164 ?? 'no phone'} · {flags.join(', ')}
                </p>
              </div>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}

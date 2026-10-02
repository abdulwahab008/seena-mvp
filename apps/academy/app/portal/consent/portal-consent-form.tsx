'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useTransition } from 'react';
import { toast } from 'sonner';
import { recordPortalConsent } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type PortalPurpose = {
  code: string;
  descriptionEn: string;
  descriptionUr: string | null;
  bodyEn: string;
  myDecision: string | null;
  myDecisionAt: string | null;
  effective: boolean;
  hasConflict: boolean;
};

export function PortalConsentForm({
  childOptions,
  selectedId,
  guardianId,
  purposes,
}: {
  // Not named `children`: React treats that prop specially, and a list of
  // students is not a render tree.
  childOptions: Array<{ id: string; name: string }>;
  selectedId: string;
  guardianId: string;
  purposes: PortalPurpose[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  const submit = (purposeCode: string, decision: 'granted' | 'denied' | 'withdrawn') => {
    const fd = new FormData();
    fd.set('studentId', selectedId);
    fd.set('purposeCode', purposeCode);
    fd.set('guardianId', guardianId);
    fd.set('decision', decision);
    fd.set('channel', 'portal');

    startTransition(async () => {
      const result = await recordPortalConsent({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success('Your choice has been recorded.');
      router.refresh();
    });
  };

  return (
    <div className="space-y-6">
      {childOptions.length > 1 && (
        <div className="flex flex-wrap gap-2" data-testid="portal-consent-child-selector">
          {childOptions.map((c) => (
            <Link
              key={c.id}
              href={`/portal/consent?child=${c.id}`}
              data-testid={`portal-consent-child-${c.name}`}
              className={`rounded-full border px-3 py-1 text-sm ${
                c.id === selectedId ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
              }`}
            >
              {c.name}
            </Link>
          ))}
        </div>
      )}

      {purposes.map((p) => (
        <Card key={p.code} data-testid={`portal-consent-${p.code}`}>
          <CardContent className="space-y-3 p-4">
            <div>
              <p className="font-medium">{p.code.replace(/_/g, ' ')}</p>
              <p className="text-sm text-muted-foreground">{p.bodyEn}</p>
              {p.descriptionUr && <p dir="rtl" className="text-sm text-muted-foreground">{p.descriptionUr}</p>}
            </div>

            <p className="text-sm" data-testid={`portal-consent-status-${p.code}`}>
              Your answer:{' '}
              <span className="font-medium">
                {p.myDecision ? p.myDecision : 'not answered yet'}
                {p.myDecisionAt ? ` (${new Date(p.myDecisionAt).toLocaleDateString()})` : ''}
              </span>
              {' · '}
              In force for your child: <span className="font-medium">{p.effective ? 'yes' : 'no'}</span>
            </p>

            {/* AC4, from the parent's side: their own "yes" can be overridden
                by the other guardian's "no", and hiding that would make the
                page lie about what the school will actually do. */}
            {p.hasConflict && (
              <p className="text-xs text-destructive" data-testid={`portal-consent-conflict-${p.code}`}>
                Another guardian for this child has answered differently. While that stands, the school treats this as denied. The
                office will be in touch.
              </p>
            )}

            <div className="flex gap-2">
              <Button
                type="button"
                size="sm"
                disabled={pending}
                data-testid={`portal-consent-grant-${p.code}`}
                onClick={() => submit(p.code, 'granted')}
              >
                I agree
              </Button>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={pending}
                data-testid={`portal-consent-deny-${p.code}`}
                onClick={() => submit(p.code, 'denied')}
              >
                I do not agree
              </Button>
              {p.myDecision === 'granted' && (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={pending}
                  data-testid={`portal-consent-withdraw-${p.code}`}
                  onClick={() => submit(p.code, 'withdrawn')}
                >
                  Withdraw
                </Button>
              )}
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

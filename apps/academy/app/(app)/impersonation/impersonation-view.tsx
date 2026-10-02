'use client';

import * as React from 'react';
import { toast } from 'sonner';
import { endReasonLabel } from '@/lib/impersonation';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { endSession, grantConsent, startSession, withdrawConsent, type ImpersonationActionState } from './actions';

export type UserOption = { id: string; name: string; role: string };

export type ConsentRow = {
  id: string;
  scope: string;
  targetName: string;
  grantedByName: string;
  grantedAt: string;
  expiresAt: string;
  revokedAt: string | null;
  live: boolean;
};

export type SessionRow = {
  id: string;
  engineerName: string;
  targetName: string;
  targetRole: string;
  startedAt: string;
  endsAt: string;
  endedAt: string | null;
  endReason: string | null;
  readCount: number;
  writeCount: number;
  blockedWriteCount: number;
  isMine: boolean;
};

/** Radix refuses an empty item value, and 'tenant' scope is the absence of a target. */
const WHOLE_SCHOOL = '__tenant__';

const when = (iso: string) => new Date(iso).toLocaleString();

export function ImpersonationView({
  role,
  users,
  consents,
  sessions,
}: {
  role: string;
  users: UserOption[];
  consents: ConsentRow[];
  sessions: SessionRow[];
}) {
  const [pending, startTransition] = React.useTransition();
  const [consentTarget, setConsentTarget] = React.useState(WHOLE_SCHOOL);
  const [consentHours, setConsentHours] = React.useState('4');
  const [sessionTarget, setSessionTarget] = React.useState('');
  const [sessionMinutes, setSessionMinutes] = React.useState('30');

  const isOwner = role === 'owner';
  const isSupport = role === 'super_admin';
  const liveConsents = consents.filter((c) => c.live);

  const run = (
    action: (prev: ImpersonationActionState, fd: FormData) => Promise<ImpersonationActionState>,
    fd: FormData,
    ok: string,
  ) =>
    startTransition(async () => {
      // startSession/endSession redirect on success, and a redirected action
      // resolves with nothing rather than with a state object.
      const result = await action({ error: null }, fd);
      if (result?.error) toast.error(result.error);
      else toast.success(ok);
    });

  const onGrant = () => {
    const fd = new FormData();
    if (consentTarget !== WHOLE_SCHOOL) fd.set('targetUserId', consentTarget);
    fd.set('hours', consentHours);
    run(grantConsent, fd, 'Support access granted.');
  };

  const onWithdraw = (consentId: string) => {
    const fd = new FormData();
    fd.set('consentId', consentId);
    run(withdrawConsent, fd, 'Support access withdrawn. Any live session has been ended.');
  };

  const onStart = () => {
    const fd = new FormData();
    fd.set('targetUserId', sessionTarget);
    fd.set('minutes', sessionMinutes);
    run(startSession, fd, 'Session started.');
  };

  const onEnd = (sessionId: string) => {
    const fd = new FormData();
    fd.set('sessionId', sessionId);
    run(endSession, fd, 'Session ended.');
  };

  return (
    <div className="space-y-6" data-testid="impersonation-view">
      {isOwner ? (
        <Card>
          <CardHeader>
            <CardTitle>Grant support access</CardTitle>
            <CardDescription>
              Only you can do this — not a Principal, not the member of staff being helped, and never support themselves. Name one
              account, or the whole school if you do not yet know which login is broken.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-end gap-3">
            <div className="space-y-2">
              <Label htmlFor="consent-target">Who support may act as</Label>
              <Select value={consentTarget} onValueChange={setConsentTarget} disabled={pending}>
                <SelectTrigger id="consent-target" className="w-72" data-testid="consent-target">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={WHOLE_SCHOOL}>Anyone in the school</SelectItem>
                  {users.map((u) => (
                    <SelectItem key={u.id} value={u.id}>
                      {u.name} ({u.role.replace(/_/g, ' ')})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="consent-hours">Hours (1–24)</Label>
              <Input
                id="consent-hours"
                type="number"
                min={1}
                max={24}
                className="w-28"
                value={consentHours}
                onChange={(e) => setConsentHours(e.target.value)}
                disabled={pending}
                data-testid="consent-hours"
              />
            </div>
            <Button type="button" onClick={onGrant} disabled={pending} data-testid="grant-consent">
              Grant access
            </Button>
          </CardContent>
        </Card>
      ) : null}

      {isSupport ? (
        <Card>
          <CardHeader>
            <CardTitle>Start a session</CardTitle>
            <CardDescription>
              {liveConsents.length > 0
                ? 'The school has granted access. Sessions last at most 60 minutes, everything you do is recorded against your own account, and money and results cannot be changed.'
                : 'This school has not granted support access. Ask their Owner to grant it from this page.'}
            </CardDescription>
          </CardHeader>
          <CardContent className="flex flex-wrap items-end gap-3">
            <div className="space-y-2">
              <Label htmlFor="impersonation-target">Act as</Label>
              <Select value={sessionTarget} onValueChange={setSessionTarget} disabled={pending}>
                <SelectTrigger id="impersonation-target" className="w-72" data-testid="impersonation-target">
                  <SelectValue placeholder="Choose a user" />
                </SelectTrigger>
                <SelectContent>
                  {users.map((u) => (
                    <SelectItem key={u.id} value={u.id}>
                      {u.name} ({u.role.replace(/_/g, ' ')})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="impersonation-minutes">Minutes (1–60)</Label>
              <Input
                id="impersonation-minutes"
                type="number"
                min={1}
                max={60}
                className="w-28"
                value={sessionMinutes}
                onChange={(e) => setSessionMinutes(e.target.value)}
                disabled={pending}
                data-testid="impersonation-minutes"
              />
            </div>
            <Button
              type="button"
              onClick={onStart}
              disabled={pending || !sessionTarget}
              data-testid="start-impersonation"
            >
              Start session
            </Button>
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Consent</CardTitle>
          <CardDescription>
            Withdrawing is instant: it ends every live session on that consent, and the next request support makes is refused.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {consents.length === 0 ? (
            <EmptyState title="No support access has ever been granted" data-testid="no-consents" />
          ) : (
            <Table data-testid="consent-list">
              <TableHeader>
                <TableRow>
                  <TableHead>Scope</TableHead>
                  <TableHead>Granted by</TableHead>
                  <TableHead>Granted</TableHead>
                  <TableHead>Expires</TableHead>
                  <TableHead>Status</TableHead>
                  {isOwner ? <TableHead /> : null}
                </TableRow>
              </TableHeader>
              <TableBody>
                {consents.map((c) => (
                  <TableRow key={c.id} data-testid={`consent-row-${c.id}`}>
                    <TableCell>{c.targetName}</TableCell>
                    <TableCell>{c.grantedByName}</TableCell>
                    <TableCell className="whitespace-nowrap">{when(c.grantedAt)}</TableCell>
                    <TableCell className="whitespace-nowrap">{when(c.expiresAt)}</TableCell>
                    <TableCell>
                      <Badge
                        variant={c.live ? 'success' : 'outline'}
                        dot={c.live}
                        data-testid={`consent-status-${c.id}`}
                      >
                        {c.live ? 'Live' : c.revokedAt ? 'Withdrawn' : 'Expired'}
                      </Badge>
                    </TableCell>
                    {isOwner ? (
                      <TableCell className="text-right">
                        {c.live ? (
                          <Button
                            variant="outline"
                            size="sm"
                            disabled={pending}
                            onClick={() => onWithdraw(c.id)}
                            data-testid={`withdraw-consent-${c.id}`}
                          >
                            Withdraw
                          </Button>
                        ) : null}
                      </TableCell>
                    ) : null}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Impersonation log</CardTitle>
          <CardDescription>
            AC6 — every session that has ever been opened against this school: who acted as whom, from when to when, how it ended,
            and what it touched. Blocked counts the money and results changes that were refused.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {sessions.length === 0 ? (
            <EmptyState title="Nobody has ever impersonated a user here" data-testid="no-sessions" />
          ) : (
            <Table data-testid="impersonation-log">
              <TableHeader>
                <TableRow>
                  <TableHead>Support engineer</TableHead>
                  <TableHead>Acting as</TableHead>
                  <TableHead>Started</TableHead>
                  <TableHead>Ended</TableHead>
                  <TableHead numeric>Reads</TableHead>
                  <TableHead numeric>Writes</TableHead>
                  <TableHead numeric>Blocked</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {sessions.map((s) => (
                  <TableRow key={s.id} data-testid={`session-row-${s.id}`}>
                    <TableCell>{s.engineerName}</TableCell>
                    <TableCell>
                      {s.targetName}{' '}
                      <span className="text-muted-foreground">({s.targetRole.replace(/_/g, ' ')})</span>
                    </TableCell>
                    <TableCell className="whitespace-nowrap">{when(s.startedAt)}</TableCell>
                    <TableCell className="whitespace-nowrap">
                      <Badge
                        variant={s.endedAt ? 'outline' : 'destructive'}
                        dot={!s.endedAt}
                        data-testid={`session-status-${s.id}`}
                      >
                        {endReasonLabel(s.endReason)}
                      </Badge>
                    </TableCell>
                    <TableCell numeric data-testid={`session-reads-${s.id}`}>
                      {s.readCount}
                    </TableCell>
                    <TableCell numeric data-testid={`session-writes-${s.id}`}>
                      {s.writeCount}
                    </TableCell>
                    <TableCell numeric data-testid={`session-blocked-${s.id}`}>
                      {s.blockedWriteCount}
                    </TableCell>
                    <TableCell className="text-right">
                      {!s.endedAt && (isOwner || s.isMine) ? (
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={pending}
                          onClick={() => onEnd(s.id)}
                          data-testid={`end-session-${s.id}`}
                        >
                          End now
                        </Button>
                      ) : null}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

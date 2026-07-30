'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { setSiblingDiscountScheme, detectSiblingGroups, type ScanState } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type Scheme = { id: string; code: string; name_en: string };
export type RankRow = { siblingRank: number; schemeId: string; schemeName: string };

function RankSchemeForm({ schemes }: { schemes: Scheme[] }) {
  const [pending, startTransition] = useTransition();
  const [siblingRank, setSiblingRank] = useState('2');
  const [schemeId, setSchemeId] = useState('');

  const onSubmit = () => {
    if (!schemeId) {
      toast.error('Choose a scheme.');
      return;
    }
    const fd = new FormData();
    fd.set('siblingRank', siblingRank);
    fd.set('schemeId', schemeId);
    startTransition(async () => {
      const result = await setSiblingDiscountScheme({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Rank mapping saved.');
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
      <div className="space-y-1">
        <Label htmlFor="siblingRank">Sibling rank</Label>
        <Input
          id="siblingRank"
          type="number"
          min={2}
          className="w-24"
          value={siblingRank}
          onChange={(e) => setSiblingRank(e.target.value)}
        />
      </div>
      <div className="space-y-1">
        <Label>Scheme</Label>
        <Select value={schemeId} onValueChange={setSchemeId}>
          <SelectTrigger data-testid="rank-scheme-trigger" className="w-48">
            <SelectValue placeholder="Select a scheme" />
          </SelectTrigger>
          <SelectContent>
            {schemes.map((s) => (
              <SelectItem key={s.id} value={s.id}>
                {s.name_en}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <Button type="button" disabled={pending} onClick={onSubmit} data-testid="save-rank-scheme-button">
        {pending ? 'Saving…' : 'Save mapping'}
      </Button>
    </div>
  );
}

export function SiblingDiscountView({
  campusId,
  sessionId,
  ranks,
  schemes,
  canConfigure,
}: {
  campusId: string;
  sessionId: string;
  ranks: RankRow[];
  schemes: Scheme[];
  canConfigure: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<ScanState>({ error: null });

  const runScan = () => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    startTransition(async () => {
      const outcome = await detectSiblingGroups({ error: null }, fd);
      if (outcome.error) toast.error(outcome.error);
      else {
        toast.success('Scan complete.');
        setResult(outcome);
      }
    });
  };

  return (
    <div className="space-y-4">
      {canConfigure && <RankSchemeForm schemes={schemes} />}

      <div className="space-y-2">
        {ranks.length === 0 ? (
          <p className="text-sm text-muted-foreground">No rank mappings configured yet.</p>
        ) : (
          ranks.map((r) => (
            <Card key={r.siblingRank} data-testid={`rank-row-${r.siblingRank}`}>
              <CardContent className="flex items-center justify-between p-3 text-sm">
                <span>Rank {r.siblingRank}</span>
                <span className="text-muted-foreground">{r.schemeName}</span>
              </CardContent>
            </Card>
          ))
        )}
      </div>

      <div className="rounded-lg border p-4">
        <Button type="button" disabled={pending} onClick={runScan} data-testid="run-sibling-scan-button">
          {pending ? 'Scanning…' : 'Run sibling detection scan'}
        </Button>
        {result.error === null && result.groupsFound !== undefined && (
          <p data-testid="sibling-scan-result" className="mt-2 text-sm">
            Groups found: {result.groupsFound} · Proposals created: {result.proposalsCreated} · Needs review:{' '}
            {result.needsReview?.length ?? 0}
          </p>
        )}
      </div>
    </div>
  );
}

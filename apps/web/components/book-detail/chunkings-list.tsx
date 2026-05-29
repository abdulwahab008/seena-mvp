'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  CHUNK_STRATEGIES,
  EMBEDDING_MODELS,
  type StrategyKey,
  type EmbeddingModelKey,
} from '@seena/shared/rag/strategies';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

export type ChunkingRow = {
  id: string;
  strategy: string;
  strategyConfig: unknown;
  embeddingModel: string;
  embeddingDimensions: number;
  namespace: string;
  chunkCount: number;
  status: string;
  isDefault: boolean;
  failureReason: string | null;
  createdAt: string | Date | null;
  readyAt: string | Date | null;
};

type Props = {
  bookId: string;
  chunkings: ChunkingRow[];
};

function statusClass(status: string): string {
  switch (status) {
    case 'ready':
      return 'bg-green-100 text-green-800';
    case 'embedding':
      return 'bg-blue-100 text-blue-800';
    case 'failed':
      return 'bg-red-100 text-red-800';
    case 'pending':
    default:
      return 'bg-amber-100 text-amber-800';
  }
}

function strategyLabel(strategy: string): string {
  return (CHUNK_STRATEGIES as Record<string, { label: string }>)[strategy]?.label ?? strategy;
}

function modelLabel(model: string): string {
  return (EMBEDDING_MODELS as Record<string, { label: string }>)[model]?.label ?? model;
}

function configSummary(config: unknown): string | null {
  if (!config || typeof config !== 'object') return null;
  const c = config as { targetTokens?: number; overlapTokens?: number };
  if (typeof c.targetTokens !== 'number') return null;
  return `${c.targetTokens}/${c.overlapTokens ?? 0} tokens`;
}

export function ChunkingsList({ bookId, chunkings }: Props) {
  const router = useRouter();
  const [busyId, setBusyId] = useState<string | null>(null);

  async function setDefault(chunkingId: string) {
    setBusyId(chunkingId);
    try {
      const res = await fetch(`/api/books/${bookId}/chunkings/${chunkingId}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ isDefault: true }),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error ?? 'failed to set default');
      }
      toast.success('Default chunking updated.');
      router.refresh();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusyId(null);
    }
  }

  async function remove(chunkingId: string) {
    if (
      !confirm(
        'Delete this chunking? Its vectors will be removed from Pinecone. This cannot be undone.',
      )
    ) {
      return;
    }
    setBusyId(chunkingId);
    try {
      const res = await fetch(`/api/books/${bookId}/chunkings/${chunkingId}`, {
        method: 'DELETE',
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error ?? 'failed to delete chunking');
      }
      toast.success('Chunking deleted.');
      router.refresh();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusyId(null);
    }
  }

  if (chunkings.length === 0) {
    return (
      <Card>
        <CardContent className="p-8 text-center text-sm text-muted-foreground">
          No chunkings yet. Click &quot;New chunking&quot; to create one.
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="overflow-x-auto rounded-lg border">
      <table className="w-full text-sm">
        <thead className="bg-muted/40 text-left">
          <tr>
            <th className="px-3 py-2 font-medium">Strategy</th>
            <th className="px-3 py-2 font-medium">Embedding</th>
            <th className="px-3 py-2 font-medium">Chunks</th>
            <th className="px-3 py-2 font-medium">Status</th>
            <th className="px-3 py-2 font-medium">Default</th>
            <th className="px-3 py-2 font-medium text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          {chunkings.map((c) => {
            const cfg = configSummary(c.strategyConfig);
            const busy = busyId === c.id;
            return (
              <tr key={c.id} className="border-t">
                <td className="px-3 py-2 align-top">
                  <div className="font-medium">{strategyLabel(c.strategy)}</div>
                  {cfg ? <div className="text-xs text-muted-foreground">{cfg}</div> : null}
                  <div className="mt-1 truncate text-xs text-muted-foreground" title={c.namespace}>
                    ns: {c.namespace}
                  </div>
                </td>
                <td className="px-3 py-2 align-top">
                  <div>{modelLabel(c.embeddingModel)}</div>
                  <div className="text-xs text-muted-foreground">{c.embeddingDimensions}-d</div>
                </td>
                <td className="px-3 py-2 align-top">{c.chunkCount}</td>
                <td className="px-3 py-2 align-top">
                  <span
                    className={`inline-flex rounded px-2 py-0.5 text-xs font-medium ${statusClass(c.status)}`}
                  >
                    {c.status}
                  </span>
                  {c.failureReason ? (
                    <div className="mt-1 max-w-xs text-xs text-red-600">{c.failureReason}</div>
                  ) : null}
                </td>
                <td className="px-3 py-2 align-top">
                  {c.isDefault ? (
                    <span className="inline-flex rounded bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
                      default
                    </span>
                  ) : (
                    <span className="text-xs text-muted-foreground">—</span>
                  )}
                </td>
                <td className="px-3 py-2 align-top">
                  <div className="flex justify-end gap-2">
                    {!c.isDefault && c.status === 'ready' ? (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setDefault(c.id)}
                        disabled={busy}
                      >
                        {busy ? '…' : 'Set default'}
                      </Button>
                    ) : null}
                    {!c.isDefault ? (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => remove(c.id)}
                        disabled={busy}
                      >
                        {busy ? '…' : 'Delete'}
                      </Button>
                    ) : null}
                  </div>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// Helpers re-exported for type-checking by callers; keep types loose to match the JSON-shape returned by the server.
export type { StrategyKey, EmbeddingModelKey };

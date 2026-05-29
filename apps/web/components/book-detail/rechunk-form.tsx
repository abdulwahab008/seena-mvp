'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import {
  CHUNK_STRATEGIES,
  EMBEDDING_MODELS,
  DEFAULT_STRATEGY_KEY,
  DEFAULT_EMBEDDING_MODEL_KEY,
  type StrategyKey,
  type EmbeddingModelKey,
} from '@seena/shared/rag/strategies';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Label } from '@/components/ui/label';

type Props = { bookId: string };

export function RechunkForm({ bookId }: Props) {
  const router = useRouter();
  const [strategy, setStrategy] = useState<StrategyKey>(DEFAULT_STRATEGY_KEY);
  const [embeddingModel, setEmbeddingModel] = useState<EmbeddingModelKey>(
    DEFAULT_EMBEDDING_MODEL_KEY,
  );
  const [submitting, setSubmitting] = useState(false);

  const strategyMeta = CHUNK_STRATEGIES[strategy];
  const modelMeta = EMBEDDING_MODELS[embeddingModel];

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    try {
      const res = await fetch(`/api/books/${bookId}/chunkings`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ strategy, embeddingModel }),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(err.error ?? 'failed to start chunking');
      }
      toast.success('Chunking started — this will run in the background.');
      router.refresh();
    } catch (err) {
      toast.error((err as Error).message);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">New chunking</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-4">
          <div>
            <Label htmlFor="strategy">Strategy</Label>
            <select
              id="strategy"
              value={strategy}
              onChange={(e) => setStrategy(e.target.value as StrategyKey)}
              className="mt-1 flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
            >
              {Object.values(CHUNK_STRATEGIES).map((s) => (
                <option key={s.key} value={s.key}>
                  {s.label}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-muted-foreground">{strategyMeta.description}</p>
          </div>

          <div>
            <Label htmlFor="embedding-model">Embedding model</Label>
            <select
              id="embedding-model"
              value={embeddingModel}
              onChange={(e) => setEmbeddingModel(e.target.value as EmbeddingModelKey)}
              className="mt-1 flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
            >
              {Object.values(EMBEDDING_MODELS).map((m) => (
                <option key={m.key} value={m.key}>
                  {m.label}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-muted-foreground">
              {modelMeta.description} · {modelMeta.dimensions}-d
            </p>
          </div>

          <div className="flex justify-end">
            <Button type="submit" disabled={submitting}>
              {submitting ? 'Starting…' : 'Start chunking'}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

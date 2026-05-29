/**
 * LLM-as-judge reranker. Asks a cheap, fast model to score how relevant each
 * candidate chunk is to the query, then sorts by score and trims to topN.
 *
 * Uses the existing OpenRouter client — no new vendor / API key required.
 * Default model: `google/gemini-3.5-flash` (configurable via OPENROUTER_RERANK_MODEL).
 *
 * Pattern: over-fetch from Pinecone (e.g. 50), rerank, trim to topK (e.g. 12).
 *
 * Cost: ~$0.001 per call with Gemini Flash on 50 candidates.
 * Latency: ~1-2s, vs ~200ms for a dedicated reranker. Acceptable in front of a
 * 30-60s LLM generation.
 */

import { llm } from '../llm';
import { env } from '../env';

export type RerankCandidate = { id: string; text: string };

export type RerankResult = {
  id: string;
  /** 0–10 relevance score from the judge. */
  score: number;
};

export type RerankTelemetry = {
  model: string;
  candidateCount: number;
  topN: number;
  latencyMs: number;
  inputTokens: number;
  outputTokens: number;
};

const CHUNK_PREVIEW_CHARS = 500;
const MAX_CANDIDATES = 60;

const SYSTEM_PROMPT = `You score how relevant each document is to the user's query for retrieving textbook chunks to answer an exam-generation request.

Scoring: 0 = irrelevant. 5 = tangentially related. 10 = exactly what the query asks for.

Output STRICTLY a JSON object: { "scores": [{ "i": <doc index>, "s": <0-10> }, ...] }. Sorted by score descending. One entry per input document. No prose.`;

export async function rerank(
  query: string,
  candidates: RerankCandidate[],
  opts: { topN?: number } = {},
): Promise<{ results: RerankResult[]; telemetry: RerankTelemetry }> {
  const model = env().OPENROUTER_RERANK_MODEL;
  const topN = Math.min(opts.topN ?? candidates.length, candidates.length);

  if (candidates.length <= 1) {
    return {
      results: candidates.map((c) => ({ id: c.id, score: 10 })),
      telemetry: {
        model,
        candidateCount: candidates.length,
        topN: candidates.length,
        latencyMs: 0,
        inputTokens: 0,
        outputTokens: 0,
      },
    };
  }

  // Cap to avoid huge prompts. The reranker is most useful on 30-60 candidates.
  const capped = candidates.slice(0, MAX_CANDIDATES);
  const numbered = capped
    .map((c, i) => `[${i}] ${c.text.slice(0, CHUNK_PREVIEW_CHARS).replace(/\s+/g, ' ').trim()}`)
    .join('\n\n');

  const startedAt = Date.now();
  const completion = await llm().chat.completions.create({
    model,
    max_tokens: 2000,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      {
        role: 'user',
        content: `QUERY: ${query}\n\nDOCUMENTS:\n${numbered}\n\nReturn { "scores": [...] } with one entry per document, sorted by score descending.`,
      },
    ],
    response_format: { type: 'json_object' },
  });
  const latencyMs = Date.now() - startedAt;

  const raw = completion.choices[0]?.message?.content ?? '{}';
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`rerank: model returned non-JSON output: ${raw.slice(0, 200)}`);
  }
  const scoresRaw =
    Array.isArray((parsed as { scores?: unknown }).scores)
      ? (parsed as { scores: unknown[] }).scores
      : Array.isArray(parsed)
        ? (parsed as unknown[])
        : [];

  const results: RerankResult[] = [];
  for (const s of scoresRaw) {
    if (typeof s !== 'object' || s === null) continue;
    const o = s as { i?: unknown; s?: unknown; index?: unknown; score?: unknown };
    const idx = typeof o.i === 'number' ? o.i : typeof o.index === 'number' ? o.index : NaN;
    const score = typeof o.s === 'number' ? o.s : typeof o.score === 'number' ? o.score : NaN;
    if (!Number.isFinite(idx) || !Number.isFinite(score)) continue;
    const c = capped[idx];
    if (!c) continue;
    results.push({ id: c.id, score });
  }
  results.sort((a, b) => b.score - a.score);

  return {
    results: results.slice(0, topN),
    telemetry: {
      model,
      candidateCount: capped.length,
      topN,
      latencyMs,
      inputTokens: completion.usage?.prompt_tokens ?? 0,
      outputTokens: completion.usage?.completion_tokens ?? 0,
    },
  };
}

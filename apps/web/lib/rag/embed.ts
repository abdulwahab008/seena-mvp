import { llm } from '../llm';
import { env } from '../env';

const BATCH_SIZE = 100;

export async function embedTexts(texts: string[], model?: string): Promise<number[][]> {
  if (texts.length === 0) return [];
  const useModel = model ?? env().OPENROUTER_EMBEDDING_MODEL;
  const out: number[][] = [];
  for (let i = 0; i < texts.length; i += BATCH_SIZE) {
    const batch = texts.slice(i, i + BATCH_SIZE);
    const res = await llm().embeddings.create({
      model: useModel,
      input: batch,
      encoding_format: 'float',
    });
    for (const item of res.data) out.push(item.embedding);
  }
  return out;
}

export async function embedQuery(text: string, model?: string): Promise<number[]> {
  const [v] = await embedTexts([text], model);
  if (!v) throw new Error('failed to embed query');
  return v;
}

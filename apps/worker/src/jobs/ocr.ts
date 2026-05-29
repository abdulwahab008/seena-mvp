import { DocumentProcessorServiceClient } from '@google-cloud/documentai';
import type { PageText } from '@seena/shared/rag/chunk';
import { env } from '../env.js';

let _client: DocumentProcessorServiceClient | null = null;

function client() {
  if (_client) return _client;
  _client = new DocumentProcessorServiceClient();
  return _client;
}

export function isOcrConfigured(): boolean {
  const e = env();
  return Boolean(
    e.GOOGLE_DOCUMENT_AI_PROJECT &&
      e.GOOGLE_DOCUMENT_AI_LOCATION &&
      e.GOOGLE_DOCUMENT_AI_PROCESSOR &&
      e.GOOGLE_APPLICATION_CREDENTIALS,
  );
}

/**
 * Run a PDF buffer through Google Document AI. Returns per-page text.
 * Throws if OCR is not configured — callers should call `isOcrConfigured()` first.
 */
export async function ocrPdf(buffer: Buffer): Promise<PageText[]> {
  if (!isOcrConfigured()) throw new Error('Google Document AI not configured');
  const e = env();
  const name = `projects/${e.GOOGLE_DOCUMENT_AI_PROJECT}/locations/${e.GOOGLE_DOCUMENT_AI_LOCATION}/processors/${e.GOOGLE_DOCUMENT_AI_PROCESSOR}`;
  const [response] = await client().processDocument({
    name,
    rawDocument: { content: buffer.toString('base64'), mimeType: 'application/pdf' },
  });
  const doc = response.document;
  if (!doc) throw new Error('Document AI returned empty response');
  const fullText = doc.text ?? '';
  const pages = (doc.pages ?? []).map((p, i) => {
    const segments =
      p.layout?.textAnchor?.textSegments?.map((s) => {
        const start = Number(s.startIndex ?? 0);
        const end = Number(s.endIndex ?? 0);
        return fullText.slice(start, end);
      }) ?? [];
    return { page: i + 1, text: segments.join('\n').trim() };
  });
  return pages;
}

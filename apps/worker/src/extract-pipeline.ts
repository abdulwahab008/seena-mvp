import type { PageText } from '@seena/shared/rag/chunk';
import { env } from './env.js';
import { extractPages } from './extract.js';
import { isOcrConfigured, ocrPdf } from './jobs/ocr.js';
import { ocrPdfWithVisionLlm, type VisionOcrOptions } from './jobs/vision-ocr.js';

export type ExtractResult = {
  pages: PageText[];
  numPages: number;
  ocrMethod: 'pdf-parse' | 'vision-llm' | 'document-ai';
  ocrModel: string | null;
  needsOcr: boolean;
};

export type ExtractOptions = {
  /** Optional logging tag — typically a bookId — included in console messages. */
  tag?: string;
  /**
   * Vision-OCR specific knobs. Only applied if extraction falls into the vision
   * path. Allows the caller to resume from a partially-OCR'd state and persist
   * each batch as it completes.
   */
  vision?: VisionOcrOptions;
};

/**
 * Run pdf-parse first; if text density is too low, fall back to OCR (Document
 * AI when configured, otherwise the OpenRouter vision model).
 *
 * Shared by the initial book-process job and the book-rechunk legacy backfill
 * path. The output is suitable for inserting into `book_pages`.
 */
// OCR is the expensive LLM path — cap pages so a huge scanned PDF can't trigger
// hundreds of vision calls. Text PDFs above this still parse (pdf-parse is cheap).
const MAX_OCR_PAGES = 800;

export async function extractPagesWithOcr(
  buffer: Buffer,
  opts: ExtractOptions = {},
): Promise<ExtractResult> {
  const tag = opts.tag ?? 'extract';
  let { pages, numPages, totalChars } = await extractPages(buffer);
  let ocrMethod: ExtractResult['ocrMethod'] = 'pdf-parse';
  let ocrModel: string | null = null;
  let needsOcr = false;

  const charsPerPage = totalChars / Math.max(numPages, 1);
  if (charsPerPage >= 100) {
    return { pages, numPages, ocrMethod, ocrModel, needsOcr };
  }

  needsOcr = true;
  if (numPages > MAX_OCR_PAGES) {
    throw new Error(
      `PDF has ${numPages} pages; OCR is capped at ${MAX_OCR_PAGES}. Upload a file with selectable text or split it.`,
    );
  }
  if (isOcrConfigured()) {
    console.log(`[extract] ${tag} text density low, running Document AI OCR`);
    const ocrPages = await ocrPdf(buffer);
    pages = ocrPages;
    numPages = ocrPages.length;
    ocrMethod = 'document-ai';
    ocrModel = 'google-document-ai';
    return { pages, numPages, ocrMethod, ocrModel, needsOcr };
  }

  console.log(`[extract] ${tag} text density low, running vision OCR via OpenRouter`);
  const visionModel = env().OPENROUTER_VISION_MODEL ?? 'google/gemini-3.5-flash';
  const visionPages = await ocrPdfWithVisionLlm(buffer, numPages, opts.vision ?? {});
  if (visionPages.length > 0) {
    pages = visionPages;
    numPages = visionPages.length;
    ocrMethod = 'vision-llm';
    ocrModel = visionModel;
    const totalVisionChars = visionPages.reduce((n, p) => n + p.text.length, 0);
    console.log(
      `[extract] ${tag} vision OCR produced ${numPages} pages, ${totalVisionChars} chars`,
    );
  } else {
    console.warn(
      `[extract] ${tag} vision OCR returned no pages — proceeding with sparse text`,
    );
  }

  return { pages, numPages, ocrMethod, ocrModel, needsOcr };
}

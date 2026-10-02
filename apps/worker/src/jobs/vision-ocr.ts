import type { PageText } from '@seena/shared/rag/chunk';
import { PDFDocument } from 'pdf-lib';
import { llm } from '../openai.js';
import { env } from '../env.js';

const SYSTEM_PROMPT = `You are an OCR service for textbook PDFs. Extract ALL readable text from the document.

OUTPUT FORMAT: For each page, emit exactly one marker line "<<<PAGE n>>>" (where n is the 1-based page number within the PDF you are given) followed by the page text. Preserve original line order. Include math expressions, headings, exercise numbers, table contents, and captions. Skip page numbers in the running text, decorative elements, and watermarks.

Do NOT add commentary, explanations, or summaries. Output ONLY the markers and extracted text.`;

const USER_PROMPT = `Extract all text from this PDF, page by page, using <<<PAGE n>>> markers as instructed.`;

// Anthropic caps at 100 pages per request; we use 30 to keep output tokens
// under our 16k-per-call budget (textbook pages are dense).
const PAGES_PER_BATCH = 30;
const MAX_OUTPUT_TOKENS = 16000;
const MAX_BATCH_RETRIES = 3;
const RETRY_BACKOFF_MS = 4000;

const IMAGE_SYSTEM_PROMPT = `You are an OCR service. Extract ALL readable text from this image exactly as written, preserving line order. Include math expressions, question numbers, and handwritten answers. Do NOT add commentary, explanations, or summaries — output only the extracted text.`;
const IMAGE_USER_PROMPT = 'Extract all text from this image.';
const IMAGE_MAX_OUTPUT_TOKENS = 4000;

export type ImageOcrResult = { text: string; inputTokens: number; outputTokens: number };

/**
 * OCR a single image (e.g. a photographed/scanned answer sheet uploaded as
 * PNG/JPEG/WebP rather than a PDF) via the vision model directly, as an
 * `image_url` content part rather than routing it through pdf-parse.
 */
export async function ocrImageWithVisionLlm(
  imageBuffer: Buffer,
  mimeType: string,
): Promise<ImageOcrResult> {
  const base64 = imageBuffer.toString('base64');
  const completion = await llm().chat.completions.create({
    model: env().OPENROUTER_VISION_MODEL ?? 'google/gemini-3.5-flash',
    max_tokens: IMAGE_MAX_OUTPUT_TOKENS,
    messages: [
      { role: 'system', content: IMAGE_SYSTEM_PROMPT },
      {
        role: 'user',
        content: [
          { type: 'image_url', image_url: { url: `data:${mimeType};base64,${base64}` } },
          { type: 'text', text: IMAGE_USER_PROMPT },
        ],
      },
    ],
  });
  const choice = completion.choices?.[0];
  if (!choice) {
    throw new Error(`image OCR returned no choices: ${JSON.stringify(completion).slice(0, 500)}`);
  }
  return {
    text: (choice.message?.content ?? '').trim(),
    inputTokens: completion.usage?.prompt_tokens ?? 0,
    outputTokens: completion.usage?.completion_tokens ?? 0,
  };
}

export type VisionOcrOptions = {
  /**
   * Skip batches whose final 1-based page number is ≤ this. Used by callers
   * resuming after a stall — pass the highest already-persisted page number.
   */
  skipPageNumbersBeforeOrEqual?: number;
  /**
   * Called once per successful batch with the OCR'd pages from that batch.
   * Throwing here aborts the whole OCR. Used by callers to incrementally
   * persist `book_pages` rows so retries can resume.
   */
  onBatchComplete?: (pages: PageText[]) => Promise<void> | void;
};

/**
 * OCR a PDF by splitting into page-batches and sending each batch to Claude
 * via OpenRouter (which forwards to Anthropic's native PDF document support).
 *
 * Per-batch retry: transient network errors (ENOTFOUND, ECONNRESET, 5xx)
 * retry with exponential backoff before giving up on the batch.
 */
export type VisionOcrResult = {
  pages: PageText[];
  inputTokens: number;
  outputTokens: number;
};

export async function ocrPdfWithVisionLlm(
  pdfBuffer: Buffer,
  _approxPageCount: number,
  opts: VisionOcrOptions = {},
): Promise<VisionOcrResult> {
  const sourceDoc = await PDFDocument.load(pdfBuffer, { ignoreEncryption: true });
  const totalPages = sourceDoc.getPageCount();
  console.log(`[vision-ocr] source PDF has ${totalPages} pages`);

  const out: PageText[] = [];
  let inputTokens = 0;
  let outputTokens = 0;
  const skipUntil = opts.skipPageNumbersBeforeOrEqual ?? 0;

  for (let start = 0; start < totalPages; start += PAGES_PER_BATCH) {
    const end = Math.min(start + PAGES_PER_BATCH, totalPages);
    const batchSize = end - start;

    if (end <= skipUntil) {
      console.log(`[vision-ocr] skipping batch ${start + 1}-${end} (already persisted)`);
      continue;
    }

    console.log(`[vision-ocr] batch ${start + 1}–${end} of ${totalPages}`);

    const subDoc = await PDFDocument.create();
    const pageIndices = Array.from({ length: batchSize }, (_, i) => start + i);
    const copied = await subDoc.copyPages(sourceDoc, pageIndices);
    for (const p of copied) subDoc.addPage(p);
    const subBytes = await subDoc.save();
    const subBase64 = Buffer.from(subBytes).toString('base64');

    let raw: string | null = null;
    let lastErr: unknown = null;
    for (let attempt = 1; attempt <= MAX_BATCH_RETRIES; attempt++) {
      try {
        const completion = await llm().chat.completions.create({
          model: env().OPENROUTER_VISION_MODEL ?? 'google/gemini-3.5-flash',
          max_tokens: MAX_OUTPUT_TOKENS,
          messages: [
            { role: 'system', content: SYSTEM_PROMPT },
            {
              role: 'user',
              content: [
                {
                  type: 'file',
                  file: {
                    filename: `pages_${start + 1}_${end}.pdf`,
                    file_data: `data:application/pdf;base64,${subBase64}`,
                  },
                } as never,
                { type: 'text', text: USER_PROMPT },
              ],
            },
          ],
        });
        const choice = completion.choices?.[0];
        if (!choice) {
          const errBody = (completion as unknown as { error?: unknown }).error;
          throw new Error(
            `vision OCR returned no choices: ${JSON.stringify(errBody ?? completion).slice(0, 500)}`,
          );
        }
        raw = choice.message?.content ?? '';
        inputTokens += completion.usage?.prompt_tokens ?? 0;
        outputTokens += completion.usage?.completion_tokens ?? 0;
        break;
      } catch (err) {
        lastErr = err;
        const isTransient = isTransientError(err);
        console.warn(
          `[vision-ocr] batch ${start + 1}-${end} attempt ${attempt}/${MAX_BATCH_RETRIES} failed (${isTransient ? 'transient' : 'permanent'}): ${(err as Error).message}`,
        );
        if (!isTransient || attempt === MAX_BATCH_RETRIES) break;
        await new Promise((r) => setTimeout(r, RETRY_BACKOFF_MS * attempt));
      }
    }

    if (raw === null) {
      console.error(`[vision-ocr] batch ${start + 1}-${end} giving up`, lastErr);
      // Continue with next batch — partial coverage is better than total loss.
      continue;
    }

    const batchPages = parsePagedOutput(raw).map((p) => ({
      page: start + p.page,
      text: p.text,
    }));
    out.push(...batchPages);

    console.log(
      `[vision-ocr] batch ${start + 1}-${end} produced ${batchPages.length} pages, ${batchPages.reduce((n, p) => n + p.text.length, 0)} chars`,
    );

    if (opts.onBatchComplete && batchPages.length > 0) {
      try {
        await opts.onBatchComplete(batchPages);
      } catch (err) {
        // Persistence failure is the caller's responsibility; surface and abort.
        throw new Error(
          `[vision-ocr] onBatchComplete handler threw: ${(err as Error).message}`,
        );
      }
    }
  }

  return { pages: out, inputTokens, outputTokens };
}

function isTransientError(err: unknown): boolean {
  const msg = String((err as Error)?.message ?? err);
  if (/ENOTFOUND|ECONNRESET|ETIMEDOUT|ECONNREFUSED|EAI_AGAIN/i.test(msg)) return true;
  const code = (err as { code?: number; status?: number })?.code ?? (err as { code?: number; status?: number })?.status;
  if (typeof code === 'number' && (code === 408 || code === 429 || code === 502 || code === 503 || code === 504 || code === 524)) {
    return true;
  }
  if (/timeout|temporarily unavailable|gateway/i.test(msg)) return true;
  return false;
}

function parsePagedOutput(raw: string): PageText[] {
  const pages: PageText[] = [];
  const parts = raw.split(/<<<PAGE\s+(\d+)>>>\s*/i);
  for (let i = 1; i < parts.length; i += 2) {
    const n = parseInt(parts[i] ?? '', 10);
    const content = (parts[i + 1] ?? '').trim();
    if (Number.isFinite(n) && content.length > 0) {
      pages.push({ page: n, text: content });
    }
  }
  if (pages.length === 0 && raw.trim().length > 100) {
    pages.push({ page: 1, text: raw.trim() });
  }
  return pages;
}

import pdfParse from 'pdf-parse';
import type { PageText } from '@seena/shared/rag/chunk';

/**
 * Best-effort page-level text extraction. pdf-parse exposes `numpages` and
 * a per-page render hook; we splice text by form-feed (\f) which most PDFs
 * emit between pages. Falls back to whole-document text if pages can't be
 * separated.
 */
export async function extractPages(buffer: Buffer): Promise<{
  pages: PageText[];
  numPages: number;
  totalChars: number;
}> {
  const result = await pdfParse(buffer);
  const numPages = result.numpages ?? 1;
  const fullText = (result.text ?? '').trim();
  const totalChars = fullText.length;

  const byFormFeed = fullText.split('\f');
  let pages: PageText[];
  if (byFormFeed.length > 1) {
    pages = byFormFeed.map((text, i) => ({ page: i + 1, text: text.trim() }));
  } else {
    // Fallback: split evenly. Crude but better than one massive page.
    const approxPerPage = Math.ceil(fullText.length / numPages);
    pages = [];
    for (let i = 0; i < numPages; i++) {
      const start = i * approxPerPage;
      pages.push({ page: i + 1, text: fullText.slice(start, start + approxPerPage).trim() });
    }
  }

  return { pages, numPages, totalChars };
}

import pdfParse from 'pdf-parse';
import type { PageText } from '@seena/shared/rag/chunk';

type PdfTextItem = { str: string; transform: number[] };
type PdfPageData = {
  pageIndex: number;
  getTextContent: (opts?: unknown) => Promise<{ items: PdfTextItem[] }>;
};

/**
 * Render one PDF page's text content. Mirrors pdf-parse's own default
 * `render_page`, but we supply it ourselves so we can capture each page's
 * text against pdf.js's real `pageIndex` instead of letting pdf-parse
 * collapse everything into one string that we'd have to guess page
 * boundaries back out of.
 */
async function renderPage(pageData: PdfPageData): Promise<string> {
  const textContent = await pageData.getTextContent({
    normalizeWhitespace: false,
    disableCombineTextItems: false,
  });
  let lastY: number | undefined;
  let text = '';
  for (const item of textContent.items) {
    const y = item.transform[5];
    text += lastY === undefined || lastY === y ? item.str : `\n${item.str}`;
    lastY = y;
  }
  return text;
}

/**
 * Page-level text extraction with real, pdf.js-reported page boundaries —
 * not inferred from form-feed characters (unreliable: most PDFs never emit
 * them) or an equal-character-count split (wrong whenever pages aren't
 * uniformly dense, which is effectively always). Wrong page numbers here
 * corrupt every `source_pages` citation downstream.
 */
export async function extractPages(buffer: Buffer): Promise<{
  pages: PageText[];
  numPages: number;
  totalChars: number;
}> {
  const pages: PageText[] = [];

  const result = await pdfParse(buffer, {
    pagerender: async (pageData: PdfPageData) => {
      const text = await renderPage(pageData);
      pages.push({ page: pageData.pageIndex + 1, text: text.trim() });
      return text;
    },
  });

  const numPages = result.numpages ?? pages.length ?? 1;
  const fullText = (result.text ?? '').trim();
  const totalChars = fullText.length;

  // pagerender is invoked once per page (pdf-parse may not guarantee call
  // order), so sort by the real page number rather than push order. Only
  // fall back to a single whole-document page if the callback never ran at
  // all (e.g. an empty or unparseable PDF).
  const resolvedPages =
    pages.length > 0 ? pages.sort((a, b) => a.page - b.page) : [{ page: 1, text: fullText }];

  return { pages: resolvedPages, numPages, totalChars };
}

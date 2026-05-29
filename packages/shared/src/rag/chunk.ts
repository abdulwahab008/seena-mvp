/**
 * Page-aware chunker for textbook PDFs.
 * Pure logic, no external deps. Used by both web and worker.
 *
 * Uses a char/4 token approximation. Swap for js-tiktoken if accuracy matters.
 */

const DEFAULT_TARGET_TOKENS = 600;
const DEFAULT_OVERLAP_TOKENS = 80;
const CHARS_PER_TOKEN = 4;

export type PageText = { page: number; text: string };

export type Chunk = {
  page: number;
  chapterLabel: string | null;
  exerciseLabel: string | null;
  tokenCount: number;
  text: string;
};

export type ChunkConfig = {
  targetTokens?: number;
  overlapTokens?: number;
};

export function approxTokenCount(text: string): number {
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

/**
 * Convert Arabic-Indic (٠-٩) and Extended Arabic-Indic / Urdu-Persian (۰-۹)
 * digit codepoints to ASCII 0–9. Keeps everything else intact. Lets the same
 * regex match "باب 5", "باب ۵", and "باب ٥".
 */
function normalizeDigits(s: string): string {
  return s
    .replace(/[٠-٩]/g, (d) => String.fromCharCode(d.charCodeAt(0) - 0x0660 + 0x30))
    .replace(/[۰-۹]/g, (d) => String.fromCharCode(d.charCodeAt(0) - 0x06F0 + 0x30));
}

function normalize(text: string): string {
  return normalizeDigits(text.replace(/\s+/g, ' '));
}

/**
 * Detect a normalized chapter / top-level unit label.
 *
 * Math/Science textbooks usually use "Unit N" or "Chapter N".
 * English/Urdu lesson-based books use "Lesson N: Title".
 * Cambridge uses "Topic N" or "Module N".
 * Urdu/Pakistani-medium books use "باب N", "سبق N", "اکائی N".
 *
 * Returns a canonical English form (`Unit N`, `Lesson N`, `Chapter N`)
 * regardless of source language so retrieval can match across languages.
 */
function detectChapter(text: string): string | null {
  const normalized = normalize(text);

  // English
  const en = normalized.match(/\b(unit|chapter|lesson|topic|module)\s*[-–:\s]+(\d+)\b/i);
  if (en && en[1] && en[2]) {
    const kind = en[1].charAt(0).toUpperCase() + en[1].slice(1).toLowerCase();
    return `${kind} ${en[2]}`;
  }

  // Urdu / Arabic — script-based detection; word boundaries are irrelevant.
  // باب = chapter, سبق = lesson, اکائی = unit, حصہ = part, الفصل = chapter (Arabic)
  const ur = normalized.match(/(باب|سبق|اکائی|اکاٸی|حصہ|الفصل)\s*[-–:\s]*(\d+)/);
  if (ur && ur[1] && ur[2]) {
    const map: Record<string, string> = {
      'باب': 'Chapter',
      'سبق': 'Lesson',
      'اکائی': 'Unit',
      'اکاٸی': 'Unit',
      'حصہ': 'Part',
      'الفصل': 'Chapter',
    };
    const kind = map[ur[1]] ?? 'Chapter';
    return `${kind} ${ur[2]}`;
  }

  return null;
}

/**
 * Section-level label patterns within a chapter. Order matters — more
 * specific multi-word patterns must come before plain single-word ones.
 *
 * Each pattern resolves to a canonical label string. The label is what
 * retrieval filters against (via $in variants on the metadata).
 */
const SECTION_PATTERNS: Array<{
  rx: RegExp;
  build: (m: RegExpMatchArray) => string;
}> = [
  // Math / science — most specific composite headings first
  {
    rx: /\b(review|miscellaneous)\s+exercise\s*[-:\s]*(\d+)\b/i,
    build: (m) => {
      const kind = m[1]!.toLowerCase() === 'review' ? 'Review Exercise' : 'Miscellaneous Exercise';
      return `${kind} ${m[2]}`;
    },
  },
  {
    rx: /\bnumerical\s+(?:problems?|exercises?)\s*[-:\s]*(\d+(?:\.\d+)?)\b/i,
    build: (m) => `Numerical Problems ${m[1]}`,
  },
  {
    rx: /\bconceptual\s+(?:questions?|problems?|exercises?)\b/i,
    build: () => 'Conceptual Questions',
  },
  {
    rx: /\bpast\s+paper\s*[-:\s]*([0-9/]+)\b/i,
    build: (m) => `Past Paper ${m[1]}`,
  },

  // English-medium subject sections — typically named, not numbered
  {
    rx: /\b(comprehension|reading\s+comprehension)\b/i,
    build: () => 'Comprehension',
  },
  {
    rx: /\b(vocabulary|word\s+power|word\s+study)\b/i,
    build: () => 'Vocabulary',
  },
  {
    rx: /\b(composition|writing\s+skills?)(?:\s+topics?)?\b/i,
    build: () => 'Composition',
  },
  {
    rx: /\b(grammar|grammar\s+practice|grammar\s+focus)\b/i,
    build: () => 'Grammar',
  },
  {
    rx: /\b(discussion\s+questions?|discussion)\b/i,
    build: () => 'Discussion',
  },

  // Generic numbered activity / practice (US-style books)
  {
    rx: /\bactivity\s*[-:\s]*(\d+)\b/i,
    build: (m) => `Activity ${m[1]}`,
  },
  {
    rx: /\bpractice\s*[-:\s]*(\d+(?:\.\d+)?)\b/i,
    build: (m) => `Practice ${m[1]}`,
  },

  // Math/Science numbered exercise (most common) — keep last among numbered
  {
    rx: /\bexercise\s*[-:\s]*(\d+(?:\.\d+)?)\b/i,
    build: (m) => `Exercise ${m[1]}`,
  },

  // Generic Q&A / question bank sections
  {
    rx: /\b(?:questions?\s+for\s+)?(?:review|self[-\s]?assessment|self[-\s]?check)\b/i,
    build: () => 'Review',
  },

  // Urdu / Arabic section keywords. No \b — Arabic/Urdu script isn't ASCII-word.
  // Canonicalize to the same English labels used by their English-medium siblings
  // so cross-language retrieval works without special casing.
  {
    rx: /(جائزہ|جائزه)\s*[-–:\s]*(\d+)?/,
    build: (m) => (m[2] ? `Review Exercise ${m[2]}` : 'Review'),
  },
  {
    rx: /(مشق|تمرین|تمرين|تمرینات)\s*[-–:\s]*(\d+(?:\.\d+)?)/,
    build: (m) => `Exercise ${m[2]}`,
  },
  {
    rx: /(تفہیم|تفہیمِ\s*متن)/,
    build: () => 'Comprehension',
  },
  {
    rx: /(لغت|لغات|الفاظ\s+کے\s+معانی)/,
    build: () => 'Vocabulary',
  },
  {
    rx: /(خلاصہ|خلاصۂ\s*سبق)/,
    build: () => 'Summary',
  },
  {
    rx: /(گرامر|قواعد)/,
    build: () => 'Grammar',
  },
];

function detectSection(text: string): string | null {
  const normalized = normalize(text);
  for (const p of SECTION_PATTERNS) {
    const m = normalized.match(p.rx);
    if (m) return p.build(m);
  }
  return null;
}

function splitIntoSentences(text: string): string[] {
  return text
    .replace(/\s+/g, ' ')
    .split(/(?<=[.!?۔])\s+(?=[A-ZА-Я۰-۹؀-ۿ])|\n{2,}/g)
    .map((s) => s.trim())
    .filter(Boolean);
}

function chunkOnePage(
  pageText: PageText,
  inheritedChapter: string | null,
  inheritedExercise: string | null,
  targetTokens: number,
  overlapTokens: number,
): { chunks: Chunk[]; lastChapter: string | null; lastExercise: string | null } {
  const sentences = splitIntoSentences(pageText.text);
  const chunks: Chunk[] = [];
  let buf: string[] = [];
  let bufTokens = 0;
  let chapter = inheritedChapter;
  let exercise = inheritedExercise;

  // Reset exercise label when the chapter genuinely changes — sub-sections
  // don't cross chapter boundaries (e.g. "Comprehension" inside Lesson 5
  // is a different thing from "Comprehension" inside Lesson 6).
  const detectedChapter = detectChapter(pageText.text);
  if (detectedChapter && detectedChapter !== chapter) {
    chapter = detectedChapter;
    exercise = null;
  }

  const detectedSection = detectSection(pageText.text);
  if (detectedSection) exercise = detectedSection;

  const flush = () => {
    if (buf.length === 0) return;
    const text = buf.join(' ').trim();
    if (text.length < 30) {
      buf = [];
      bufTokens = 0;
      return;
    }
    chunks.push({
      page: pageText.page,
      chapterLabel: chapter,
      exerciseLabel: exercise,
      tokenCount: approxTokenCount(text),
      text,
    });
    const overlap: string[] = [];
    let acc = 0;
    for (let i = buf.length - 1; i >= 0 && acc < overlapTokens; i--) {
      const sentence = buf[i];
      if (!sentence) continue;
      overlap.unshift(sentence);
      acc += approxTokenCount(sentence);
    }
    buf = overlap;
    bufTokens = acc;
  };

  for (const sentence of sentences) {
    const tokens = approxTokenCount(sentence);
    if (bufTokens + tokens > targetTokens && buf.length > 0) flush();
    buf.push(sentence);
    bufTokens += tokens;
  }
  flush();

  return { chunks, lastChapter: chapter, lastExercise: exercise };
}

export function chunkPages(pages: PageText[], config: ChunkConfig = {}): Chunk[] {
  const targetTokens = config.targetTokens ?? DEFAULT_TARGET_TOKENS;
  const overlapTokens = config.overlapTokens ?? DEFAULT_OVERLAP_TOKENS;
  const out: Chunk[] = [];
  let chapter: string | null = null;
  let exercise: string | null = null;
  for (const p of pages) {
    if (!p.text.trim()) continue;
    const { chunks, lastChapter, lastExercise } = chunkOnePage(
      p,
      chapter,
      exercise,
      targetTokens,
      overlapTokens,
    );
    out.push(...chunks);
    chapter = lastChapter;
    exercise = lastExercise;
  }
  return out;
}

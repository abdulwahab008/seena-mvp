import { z } from 'zod';

// The boundary between the school system and the Seena Exams generator
// (FR-H09). The school side hands the generator a payload whose
// `metadata_filter.syllabus_unit_id` lists the ONLY syllabus units questions
// may be drawn from; the generator returns questions that each cite one of
// them. Only DevPaperGenerator exists in this repository -- the real RAG worker
// implements the same interface and is wired in getPaperGenerator().

export const paperPayloadSchema = z.object({
  request_id: z.string().uuid(),
  title: z.string(),
  metadata_filter: z.object({ syllabus_unit_id: z.array(z.string().uuid()).min(1) }),
  units: z.array(
    z.object({
      id: z.string().uuid(),
      sequence: z.number().int(),
      title: z.string(),
      source_chapters: z.array(z.object({ book: z.string(), chapter: z.string() })),
      topics: z.array(z.object({ id: z.string().uuid(), title: z.string() })),
    }),
  ),
});
export type PaperPayload = z.infer<typeof paperPayloadSchema>;

export type GeneratedQuestion = {
  question_text: string;
  marks: number;
  syllabus_unit_id: string;
  syllabus_topic_id?: string;
  source_chapter?: string;
};

export interface PaperGenerator {
  generate(payload: PaperPayload): Promise<GeneratedQuestion[]>;
}

/** Deterministic stand-in used in development and tests: one question per topic (or per unit with no topics). */
export class DevPaperGenerator implements PaperGenerator {
  async generate(payload: PaperPayload): Promise<GeneratedQuestion[]> {
    const out: GeneratedQuestion[] = [];
    for (const unit of payload.units) {
      const chapter = unit.source_chapters[0] ? `${unit.source_chapters[0].book} / ${unit.source_chapters[0].chapter}` : undefined;
      if (unit.topics.length === 0) {
        out.push({ question_text: `Explain the main ideas of "${unit.title}".`, marks: 5, syllabus_unit_id: unit.id, source_chapter: chapter });
        continue;
      }
      for (const topic of unit.topics) {
        out.push({ question_text: `Explain "${topic.title}" with an example (from ${unit.title}).`, marks: 5, syllabus_unit_id: unit.id, syllabus_topic_id: topic.id, source_chapter: chapter });
      }
    }
    return out;
  }
}

export function getPaperGenerator(): PaperGenerator {
  return new DevPaperGenerator();
}

/** Refuses a generator result that cites a unit outside the requested scope, before it reaches the database. */
export function assertProvenance(payload: PaperPayload, questions: GeneratedQuestion[]): void {
  const allowed = new Set(payload.metadata_filter.syllabus_unit_id);
  if (questions.length === 0) throw new Error('The generator returned no questions.');
  for (const q of questions) {
    if (!allowed.has(q.syllabus_unit_id)) throw new Error(`Question cites unit ${q.syllabus_unit_id}, which is outside the requested scope.`);
  }
}

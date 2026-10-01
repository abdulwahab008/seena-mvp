import { describe, expect, it } from 'vitest';
import { assertProvenance, DevPaperGenerator, paperPayloadSchema, type PaperPayload } from './generator';

const U1 = '11111111-1111-4111-8111-111111111111';
const U2 = '22222222-2222-4222-8222-222222222222';
const U5 = '55555555-5555-4555-8555-555555555555';
const T1 = '33333333-3333-4333-8333-333333333333';

const payload: PaperPayload = paperPayloadSchema.parse({
  request_id: '99999999-9999-4999-8999-999999999999',
  title: 'Term 1',
  metadata_filter: { syllabus_unit_id: [U1, U2] },
  units: [
    { id: U1, sequence: 1, title: 'Motion', source_chapters: [{ book: 'Physics 9', chapter: 'Ch 2' }], topics: [{ id: T1, title: 'Speed' }] },
    { id: U2, sequence: 2, title: 'Force', source_chapters: [], topics: [] },
  ],
});

describe('DevPaperGenerator (FR-H09)', () => {
  it('draws one question per topic, or per unit with no topics, citing only the requested units', async () => {
    const questions = await new DevPaperGenerator().generate(payload);
    expect(questions).toHaveLength(2);
    expect(questions.map((q) => q.syllabus_unit_id)).toEqual([U1, U2]);
    expect(questions[0]?.syllabus_topic_id).toBe(T1);
    expect(questions[0]?.source_chapter).toBe('Physics 9 / Ch 2');
    expect(() => assertProvenance(payload, questions)).not.toThrow();
  });

  it('assertProvenance refuses a question from a unit outside the scope', () => {
    expect(() => assertProvenance(payload, [{ question_text: 'What is a wave?', marks: 1, syllabus_unit_id: U5 }])).toThrow(/outside the requested scope/);
  });

  it('assertProvenance refuses an empty paper', () => {
    expect(() => assertProvenance(payload, [])).toThrow(/no questions/);
  });

  it('the payload schema rejects an empty unit filter', () => {
    expect(paperPayloadSchema.safeParse({ ...payload, metadata_filter: { syllabus_unit_id: [] } }).success).toBe(false);
  });
});

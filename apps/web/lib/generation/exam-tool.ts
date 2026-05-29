/**
 * OpenAI-compatible tool definition for the structured exam output.
 * Used via OpenRouter (which translates to the underlying provider's tool format).
 */

export const EXAM_TOOL_NAME = 'submit_exam';

const examInputSchema = {
  type: 'object',
  properties: {
    title: { type: 'string', minLength: 1 },
    total_marks: { type: 'integer', minimum: 1 },
    pattern: { type: 'string' },
    sections: {
      type: 'array',
      minItems: 1,
      items: {
        type: 'object',
        properties: {
          type: { type: 'string', enum: ['mcq', 'short', 'long', 'fill_blank', 'true_false'] },
          title: { type: 'string' },
          instructions: { type: 'string' },
          questions: {
            type: 'array',
            minItems: 1,
            items: {
              type: 'object',
              properties: {
                type: {
                  type: 'string',
                  enum: ['mcq', 'short', 'long', 'fill_blank', 'true_false'],
                },
                prompt: { type: 'string', minLength: 5 },
                options: {
                  type: 'array',
                  items: { type: 'string' },
                  minItems: 2,
                  maxItems: 6,
                },
                answer: { type: 'string' },
                marks: { type: 'number', minimum: 0.5 },
                source_pages: {
                  type: 'array',
                  items: { type: 'integer', minimum: 1 },
                  minItems: 1,
                },
                explanation: { type: 'string' },
                rubric: { type: 'string' },
              },
              required: ['type', 'prompt', 'answer', 'marks', 'source_pages'],
            },
          },
        },
        required: ['type', 'title', 'instructions', 'questions'],
      },
    },
  },
  required: ['title', 'total_marks', 'pattern', 'sections'],
} as const;

export const EXAM_TOOL = {
  type: 'function' as const,
  function: {
    name: EXAM_TOOL_NAME,
    description:
      'Submit a generated exam paper as structured JSON. Every question must include source_pages.',
    parameters: examInputSchema,
  },
};

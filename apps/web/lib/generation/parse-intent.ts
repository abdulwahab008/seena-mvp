import { llm, estimateCostUsd } from '../llm';
import { env } from '../env';
import { ParsedIntent } from '@seena/shared';
import { INTENT_PARSER_SYSTEM, buildIntentParserPrompt } from '../rag/prompts';

const PARSE_TOOL = {
  type: 'function' as const,
  function: {
    name: 'submit_intent',
    description: "Submit the parsed structured intent of the user's message.",
    parameters: {
      type: 'object',
      properties: {
        intent: {
          type: 'string',
          enum: ['generate', 'regenerate', 'edit', 'explain', 'unknown'],
        },
        bookId: { type: ['string', 'null'] },
        chapter: { type: ['string', 'null'] },
        exercise: { type: ['string', 'null'] },
        patternId: { type: ['string', 'null'] },
        format: {
          type: ['string', 'null'],
          enum: ['paper', 'quiz', 'assignment', 'homework', 'midterm', 'final', 'mocktest', null],
          description:
            'High-level exam format inferred from words like "quiz", "assignment", "paper", "midterm", "final", "mock test".',
        },
        totalMarks: { type: ['integer', 'null'] },
        questionTypes: {
          type: 'array',
          items: { type: 'string', enum: ['mcq', 'short', 'long', 'fill_blank', 'true_false'] },
        },
        customSections: {
          type: 'array',
          description:
            'Set when the user explicitly specified counts (e.g. "5 MCQs and 4 short questions"). Empty when they describe a pattern without counts.',
          items: {
            type: 'object',
            properties: {
              type: { type: 'string', enum: ['mcq', 'short', 'long', 'fill_blank', 'true_false'] },
              count: { type: 'integer', minimum: 1, maximum: 50 },
              marks: { type: 'number', minimum: 0.5 },
            },
            required: ['type', 'count'],
          },
        },
        difficulty: {
          type: 'string',
          enum: ['easy', 'medium', 'hard', 'mixed'],
        },
        rationale: { type: 'string' },
      },
      required: [
        'intent',
        'bookId',
        'chapter',
        'exercise',
        'patternId',
        'format',
        'totalMarks',
        'questionTypes',
        'customSections',
        'difficulty',
      ],
    },
  },
};

export type ParseIntentResult = {
  intent: ReturnType<typeof ParsedIntent.parse>;
  costUsd: number;
  inputTokens: number;
  outputTokens: number;
};

export async function parseIntent(
  message: string,
  knownBooks: { id: string; title: string; subject: string; grade: number | null }[],
): Promise<ParseIntentResult> {
  const model = env().OPENROUTER_MODEL;
  const completion = await llm().chat.completions.create({
    model,
    max_tokens: 600,
    messages: [
      { role: 'system', content: INTENT_PARSER_SYSTEM },
      { role: 'user', content: buildIntentParserPrompt(message, knownBooks) },
    ],
    tools: [PARSE_TOOL],
    tool_choice: { type: 'function', function: { name: 'submit_intent' } },
  });

  const toolCall = completion.choices[0]?.message?.tool_calls?.[0];
  if (!toolCall || toolCall.type !== 'function') throw new Error('intent parser did not call tool');

  let raw: unknown;
  try {
    raw = JSON.parse(toolCall.function.arguments);
  } catch (e) {
    throw new Error(`intent tool arguments not valid JSON: ${(e as Error).message}`);
  }
  const intent = ParsedIntent.parse(raw);

  const inputTokens = completion.usage?.prompt_tokens ?? 0;
  const outputTokens = completion.usage?.completion_tokens ?? 0;

  return {
    intent,
    inputTokens,
    outputTokens,
    costUsd: estimateCostUsd(model, inputTokens, outputTokens),
  };
}

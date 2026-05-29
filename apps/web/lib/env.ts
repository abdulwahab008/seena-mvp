import { z } from 'zod';

const EnvSchema = z.object({
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().min(1),

  CLERK_SECRET_KEY: z.string().min(1),
  NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: z.string().min(1),

  OPENROUTER_API_KEY: z.string().min(1),
  OPENROUTER_BASE_URL: z.string().url().default('https://openrouter.ai/api/v1'),
  OPENROUTER_MODEL: z.string().default('anthropic/claude-sonnet-4.5'),
  OPENROUTER_EMBEDDING_MODEL: z.string().default('openai/text-embedding-3-large'),
  OPENROUTER_APP_NAME: z.string().default('Seena Exams'),
  OPENROUTER_APP_URL: z.string().default('http://localhost:3000'),

  PINECONE_API_KEY: z.string().min(1),
  PINECONE_INDEX: z.string().min(1),

  // Rerank model — LLM-as-judge via OpenRouter. Cheap/fast model recommended.
  OPENROUTER_RERANK_MODEL: z.string().default('google/gemini-3.5-flash'),

  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),
  SUPABASE_BUCKET: z.string().default('books'),

  GOOGLE_DOCUMENT_AI_PROJECT: z.string().optional(),
  GOOGLE_DOCUMENT_AI_LOCATION: z.string().optional(),
  GOOGLE_DOCUMENT_AI_PROCESSOR: z.string().optional(),
  GOOGLE_APPLICATION_CREDENTIALS: z.string().optional(),

  SENTRY_DSN: z.string().optional(),
  NEXT_PUBLIC_POSTHOG_KEY: z.string().optional(),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
});

export type Env = z.infer<typeof EnvSchema>;

let cached: Env | null = null;

export function env(): Env {
  if (cached) return cached;
  const parsed = EnvSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  - ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    throw new Error(`Invalid environment variables:\n${issues}\nSee infra/env.example.`);
  }
  cached = parsed.data;
  return cached;
}

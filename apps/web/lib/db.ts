import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from '@/drizzle/schema';
import { env } from './env';

declare global {
  // eslint-disable-next-line no-var
  var __pgClient: ReturnType<typeof postgres> | undefined;
}

const client =
  globalThis.__pgClient ??
  postgres(env().DATABASE_URL, {
    max: 10,
    idle_timeout: 20,
    prepare: false,
  });

if (env().NODE_ENV !== 'production') {
  globalThis.__pgClient = client;
}

export const db = drizzle(client, { schema });
export type DB = typeof db;
export { schema };

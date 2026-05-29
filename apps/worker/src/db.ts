import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from '@seena/shared/db/schema';
import { env } from './env.js';

const client = postgres(env().DATABASE_URL, {
  max: 5,
  idle_timeout: 20,
  prepare: false,
});

export const db = drizzle(client, { schema });
export { schema };

import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { processStorageDeletes } from './purge';

const ID = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;

function fakeDb(rows: { id: string; bucket: string; path: string }[], removeError: (path: string) => { message: string } | null) {
  const completed: { id: string; error?: string }[] = [];
  const db = {
    rpc: vi.fn(async (name: string, args: Record<string, unknown>) => {
      if (name === 'claim_storage_deletes') return { data: rows, error: null };
      completed.push({ id: args.p_id as string, error: args.p_error as string | undefined });
      return { data: null, error: null };
    }),
    storage: { from: () => ({ remove: async ([path]: string[]) => ({ error: removeError(path!) }) }) },
  };
  return { db: db as unknown as SupabaseClient, completed };
}

describe('processStorageDeletes', () => {
  it('removes each object and marks it done', async () => {
    const { db, completed } = fakeDb([{ id: ID(1), bucket: 'b', path: 'a.pdf' }], () => null);
    expect(await processStorageDeletes(db)).toEqual({ removed: 1, failed: 0 });
    expect(completed).toEqual([{ id: ID(1), error: undefined }]);
  });
  it('treats an object that is already gone as removed', async () => {
    const { db } = fakeDb([{ id: ID(1), bucket: 'b', path: 'a.pdf' }], () => ({ message: 'Object not found' }));
    expect(await processStorageDeletes(db)).toEqual({ removed: 1, failed: 0 });
  });
  it('records a real failure for a retry instead of marking it done', async () => {
    const { db, completed } = fakeDb([{ id: ID(2), bucket: 'b', path: 'x.pdf' }], () => ({ message: 'storage is down' }));
    expect(await processStorageDeletes(db)).toEqual({ removed: 0, failed: 1 });
    expect(completed[0]).toEqual({ id: ID(2), error: 'storage is down' });
  });
});

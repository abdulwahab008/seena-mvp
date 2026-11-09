// PostgREST returns at most 1000 rows per request, so a list that must be complete pages through.
// The query passed in needs a stable order (end it on a unique column) or pages can overlap.
export async function allRows<T>(
  fetchPage: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
): Promise<{ data: T[]; error: { message: string } | null }> {
  const rows: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await fetchPage(from, from + 999);
    if (error) return { data: rows, error };
    rows.push(...(data ?? []));
    if ((data?.length ?? 0) < 1000) return { data: rows, error: null };
  }
}

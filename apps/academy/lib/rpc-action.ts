/** Shared helpers for server actions that wrap Postgres RPCs. */
export type ActionError = { error: string | null };

export const toPaisa = (pkr: number): number => Math.round(pkr * 100);
export const pkr = (paisa: number | string | null | undefined): string => `PKR ${(Number(paisa ?? 0) / 100).toLocaleString('en-PK')}`;

/** First matching [needle, message] pair wins; the database raises stable upper-case codes. */
export function mapRpcError(message: string, table: [string, string][]): string {
  return table.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
}

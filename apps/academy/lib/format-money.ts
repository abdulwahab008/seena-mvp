// Latin digits in every language: amounts are read off paper by bank tellers.
export function formatPkrCompact(paisa: number): string {
  const pkr = paisa / 100;
  const abs = Math.abs(pkr);
  const sign = pkr < 0 ? '-' : '';
  if (abs >= 10_000_000) return `${sign}PKR ${(abs / 10_000_000).toFixed(2)} Cr`;
  if (abs >= 100_000) return `${sign}PKR ${(abs / 100_000).toFixed(2)} L`;
  return `${sign}PKR ${abs.toLocaleString('en-PK', { maximumFractionDigits: 0 })}`;
}

export function formatPct(value: number | null): string {
  return value === null ? '—' : `${value.toFixed(1)}%`;
}

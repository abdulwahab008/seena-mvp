import { z } from 'zod';

export const installmentFormSchema = z.object({
  challanNo: z.string().trim().min(1, 'Enter the challan number'),
  parts: z.string().regex(/^([2-9]|1[0-2])$/, '2 to 12 installments'),
  firstDue: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the first due date'),
});
export type InstallmentFormInput = z.infer<typeof installmentFormSchema>;

/** Equal monthly parts in whole rupees; the last part takes whatever is left over. */
export function splitPlan(totalPaisa: number, parts: number, firstDue: string): { due_date: string; amount_paisa: number }[] {
  const each = Math.floor(totalPaisa / parts / 100) * 100;
  const [y, m, d] = firstDue.split('-').map(Number) as [number, number, number];
  return Array.from({ length: parts }, (_, i) => {
    const lastDay = new Date(Date.UTC(y, m - 1 + i + 1, 0)).getUTCDate();
    const due = new Date(Date.UTC(y, m - 1 + i, Math.min(d, lastDay)));
    return { due_date: due.toISOString().slice(0, 10), amount_paisa: i === parts - 1 ? totalPaisa - each * (parts - 1) : each };
  });
}

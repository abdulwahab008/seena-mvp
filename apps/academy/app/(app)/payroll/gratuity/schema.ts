import { z } from 'zod';

const PCT = /^\d{1,2}(\.\d{1,2})?$/;
export const pfSchema = z.object({
  employeePct: z.string().regex(PCT, 'Enter a percentage'),
  employerPct: z.string().regex(PCT, 'Enter a percentage'),
});
export type PfInput = z.infer<typeof pfSchema>;

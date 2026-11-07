import { z } from 'zod';

const NUM = /^\d+(\.\d{1,2})?$/;

export const externalResultFormSchema = z.object({
  grNumber: z.string().trim().min(1, 'Enter the GR number'),
  board: z.string().trim().min(1, 'Enter the board').max(120),
  exam: z.string().trim().min(1, 'Enter the exam').max(120),
  examYear: z.string().regex(/^(19|20|21)\d{2}$/, 'Enter the year'),
  rollNo: z.string().trim().min(1, 'Enter the roll number').max(40),
  obtained: z.string().regex(NUM, 'Enter the marks'),
  total: z.string().regex(/^[1-9]\d*$/, 'Enter the total'),
  grade: z.string().trim().max(20),
});
export type ExternalResultInput = z.infer<typeof externalResultFormSchema>;

export const externalResultSchema = externalResultFormSchema.extend({
  examYear: z.coerce.number().int().min(1990).max(2100),
  obtained: z.coerce.number().min(0),
  total: z.coerce.number().int().min(1),
});

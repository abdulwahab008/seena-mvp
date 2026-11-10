import { z } from 'zod';

export const depositSchema = z.object({
  staffId: z.string().uuid('Choose a staff member'),
  targetPkr: z.coerce.number().int('Whole rupees only').positive('Enter the deposit amount').max(10_000_000),
  installmentPkr: z.coerce.number().int('Whole rupees only').positive('Enter the monthly deduction').max(10_000_000),
  startMonth: z.string().regex(/^\d{4}-\d{2}$/, 'Choose a month'),
  notes: z.string().trim().max(300).optional(),
}).refine((v) => v.installmentPkr <= v.targetPkr, { path: ['installmentPkr'], message: 'The monthly deduction cannot be more than the deposit' });

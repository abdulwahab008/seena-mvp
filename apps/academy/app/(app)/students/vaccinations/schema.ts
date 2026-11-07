import { z } from 'zod';

const DATE = /^(\d{4}-\d{2}-\d{2})?$/;

export const vaccinationSchema = z
  .object({
    grNumber: z.string().trim().min(1, 'Enter the GR number'),
    vaccine: z.string().trim().min(1, 'Enter the vaccine').max(80),
    doseNo: z.string().regex(/^([1-9]|10)$/, 'Dose 1 to 10'),
    dueOn: z.string().regex(DATE),
    givenOn: z.string().regex(DATE),
    notes: z.string().trim().max(300),
  })
  .refine((v) => v.dueOn || v.givenOn, { message: 'Enter the due date or the date given', path: ['dueOn'] });
export type VaccinationInput = z.infer<typeof vaccinationSchema>;

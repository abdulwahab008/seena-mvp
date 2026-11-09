import { z } from 'zod';

const RUPEES = /^\d{1,9}$/;
export const payScaleSchema = z
  .object({
    id: z.string().uuid().or(z.literal('')),
    code: z.string().trim().min(1, 'Enter a code, e.g. BPS-14').max(20),
    name: z.string().trim().min(1, 'Enter a name').max(100),
    minPkr: z.string().regex(RUPEES, 'Whole rupees'),
    maxPkr: z.string().regex(RUPEES, 'Whole rupees'),
    incrementPkr: z.string().regex(RUPEES, 'Whole rupees'),
  })
  .refine((v) => Number(v.maxPkr) >= Number(v.minPkr), { path: ['maxPkr'], message: 'Must be at least the minimum' });
export type PayScaleInput = z.infer<typeof payScaleSchema>;

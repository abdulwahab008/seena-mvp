import { z } from 'zod';

export const batchSchema = z.object({
  id: z.string().uuid().optional(),
  campusId: z.string().uuid(),
  name: z.string().trim().min(1, 'Enter the batch name').max(120),
  subject: z.string().trim().max(120),
  teacherId: z.union([z.string().uuid(), z.literal('')]),
  feePkr: z.string().trim().regex(/^\d+(\.\d{1,2})?$/, 'Enter the monthly fee in rupees'),
  schedule: z.string().trim().max(300),
  isActive: z.boolean(),
});
export type BatchInput = z.infer<typeof batchSchema>;

export const coachingEnrolSchema = z.object({
  batchId: z.string().uuid('Choose a batch'),
  grNumber: z.string().trim().min(1, 'Enter the GR number'),
  startsOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Enter the start date'),
});
export type CoachingEnrolInput = z.infer<typeof coachingEnrolSchema>;

export const postMonthSchema = z.object({ month: z.string().regex(/^\d{4}-\d{2}$/, 'Choose a month') });
export type PostMonthInput = z.infer<typeof postMonthSchema>;

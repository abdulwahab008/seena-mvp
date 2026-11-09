import { z } from 'zod';

export const QUICK_SMS_MAX = 640;

export const quickSmsSchema = z
  .object({
    campusId: z.string().uuid(),
    audience: z.enum(['section', 'staff', 'numbers']),
    sectionId: z.string(),
    numbers: z.string().trim().max(2000),
    body: z.string().trim().min(1, 'Write the message').max(QUICK_SMS_MAX, `At most ${QUICK_SMS_MAX} characters`),
  })
  .superRefine((v, ctx) => {
    if (v.audience === 'section' && !z.string().uuid().safeParse(v.sectionId).success) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['sectionId'], message: 'Choose a class and section' });
    }
    if (v.audience === 'numbers' && v.numbers === '') {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['numbers'], message: 'Enter at least one number' });
    }
  });
export type QuickSmsInput = z.infer<typeof quickSmsSchema>;

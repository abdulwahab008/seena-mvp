import { z } from 'zod';
import { passwordSchema } from '@/lib/auth/password';
import { STAFF_ROLES } from '@/lib/staff-roles';

const base = {
  fullName: z.string().trim().min(1, 'Enter a name').max(200),
  role: z.enum(STAFF_ROLES, { errorMap: () => ({ message: 'Choose a role' }) }),
  campusIds: z.array(z.string().uuid()).min(1, 'Choose at least one campus'),
  password: passwordSchema,
};

export const newAccountSchema = z.discriminatedUnion('loginType', [
  z.object({
    ...base,
    loginType: z.literal('username'),
    username: z
      .string()
      .trim()
      .regex(/^[a-zA-Z0-9][a-zA-Z0-9._-]{2,31}$/, '3 to 32 letters, numbers, dots, dashes or underscores'),
  }),
  z.object({ ...base, loginType: z.literal('email'), email: z.string().trim().email('Enter a valid email') }),
]);

export type NewAccountInput = z.infer<typeof newAccountSchema>;

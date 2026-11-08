import { z } from 'zod';

export const registrationSchema = z.object({
  schoolName: z.string().trim().min(2, 'Enter the school name').max(150),
  contactName: z.string().trim().min(2, 'Enter your name').max(120),
  phone: z.string().trim().regex(/^\+?[0-9 -]{10,16}$/, 'Enter a mobile number, e.g. 0300 1234567'),
  email: z.union([z.literal(''), z.string().trim().email('Enter a valid email or leave it blank')]),
  city: z.string().trim().max(80),
  students: z.string().regex(/^\d{0,6}$/, 'Enter a number'),
  message: z.string().trim().max(1000),
});
export type RegistrationInput = z.infer<typeof registrationSchema>;

import { z } from 'zod';

export const cnicExpirySchema = z.object({
  employeeCode: z.string().trim().min(1, 'Enter the employee code'),
  expiresOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the expiry date'),
});
export type CnicExpiryInput = z.infer<typeof cnicExpirySchema>;

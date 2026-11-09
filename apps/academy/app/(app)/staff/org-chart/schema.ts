import { z } from 'zod';

export const managerSchema = z.object({
  staffId: z.string().uuid('Choose a staff member'),
  managerId: z.string().uuid().or(z.literal('')),
});
export type ManagerInput = z.infer<typeof managerSchema>;

import { z } from 'zod';

export const taskSchema = z.object({
  title: z.string().trim().min(1, 'Write the task').max(200),
  assignedTo: z.string(),
  dueOn: z.string().regex(/^(\d{4}-\d{2}-\d{2})?$/),
});
export const contactSchema = z.object({
  name: z.string().trim().min(1, 'Enter the name').max(150),
  organisation: z.string().trim().max(150),
  category: z.enum(['vendor', 'medical', 'bank', 'transport', 'government', 'parent_body', 'other']),
  phone: z.string().trim().max(30),
  email: z.string().trim().max(200),
});
export type TaskInput = z.infer<typeof taskSchema>;
export type ContactInput = z.infer<typeof contactSchema>;
export const CATEGORY_LABEL: Record<ContactInput['category'], string> = {
  vendor: 'Vendor', medical: 'Medical', bank: 'Bank', transport: 'Transport', government: 'Government / board', parent_body: 'Parents body', other: 'Other',
};

import { z } from 'zod';

export const threadSchema = z.object({
  title: z.string().trim().min(1, 'Give the thread a title').max(200),
  body: z.string().trim().min(1, 'Write something').max(5000),
});
export const replySchema = z.object({
  threadId: z.string().uuid(),
  body: z.string().trim().min(1, 'Write a reply').max(5000),
});
export type ThreadInput = z.infer<typeof threadSchema>;
export type ReplyInput = z.infer<typeof replySchema>;

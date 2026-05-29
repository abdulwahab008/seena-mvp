import { z } from 'zod';

export const BookStatus = z.enum(['uploading', 'processing', 'ready', 'failed']);
export type BookStatus = z.infer<typeof BookStatus>;

export const Board = z.enum([
  'FBISE',
  'PUNJAB',
  'PINDI',
  'SINDH',
  'KP',
  'AJK',
  'CAMBRIDGE_IGCSE',
  'CAMBRIDGE_O_LEVEL',
  'CAMBRIDGE_A_LEVEL',
  'OTHER',
]);
export type Board = z.infer<typeof Board>;

export const Language = z.enum(['en', 'ur', 'mixed']);
export type Language = z.infer<typeof Language>;

export const BookMetadata = z.object({
  title: z.string().min(1).max(200),
  grade: z.number().int().min(1).max(14).nullable(),
  subject: z.string().min(1).max(80),
  board: Board,
  language: Language.default('en'),
});
export type BookMetadata = z.infer<typeof BookMetadata>;

export const Book = BookMetadata.extend({
  id: z.string().uuid(),
  orgId: z.string().uuid(),
  uploadedBy: z.string().uuid(),
  sourceUrl: z.string().url(),
  status: BookStatus,
  pageCount: z.number().int().nullable(),
  needsOcr: z.boolean(),
  createdAt: z.string().datetime(),
});
export type Book = z.infer<typeof Book>;

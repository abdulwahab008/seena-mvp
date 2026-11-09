import { z } from 'zod';

export const LOOKUP_KINDS = ['category', 'region', 'profession', 'school'] as const;
export type LookupKind = (typeof LOOKUP_KINDS)[number];

export const lookupSchema = z.object({
  kind: z.enum(LOOKUP_KINDS),
  id: z.string().uuid().optional(),
  name: z.string().trim().min(1, 'Enter a name').max(120),
  area: z.string().trim().max(120),
});
export type LookupInput = z.infer<typeof lookupSchema>;

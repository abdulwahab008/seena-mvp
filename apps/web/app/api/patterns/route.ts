import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, asc, eq } from 'drizzle-orm';
import {
  ALL_PATTERNS,
  Board,
  Format,
  PatternSection,
} from '@seena/shared';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { customRowToSpec } from '@/lib/patterns/resolver';

const CreateBody = z.object({
  name: z.string().min(1).max(120),
  format: Format,
  board: Board,
  grade: z.number().int().min(1).max(14).nullable().optional(),
  subject: z.string().min(1).max(80).nullable().optional(),
  totalMarks: z.number().int().positive(),
  sections: z.array(PatternSection).min(1),
  notes: z.string().max(2000).optional(),
  isDefault: z.boolean().optional(),
});

export async function GET() {
  try {
    const { orgId } = await requireSession();
    const rows = await db
      .select()
      .from(schema.customPatterns)
      .where(
        and(
          eq(schema.customPatterns.orgId, orgId),
          eq(schema.customPatterns.archived, false),
        ),
      )
      .orderBy(asc(schema.customPatterns.createdAt));

    return NextResponse.json({
      builtIn: ALL_PATTERNS,
      custom: rows.map(customRowToSpec),
    });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 401 });
  }
}

export async function POST(req: Request) {
  try {
    const { userId, orgId } = await requireSession();
    const body = CreateBody.parse(await req.json());

    const [row] = await db
      .insert(schema.customPatterns)
      .values({
        orgId,
        createdBy: userId,
        name: body.name,
        format: body.format,
        board: body.board,
        grade: body.grade ?? null,
        subject: body.subject ?? null,
        totalMarks: body.totalMarks,
        sections: body.sections,
        notes: body.notes ?? null,
        isDefault: body.isDefault ?? false,
      })
      .returning();
    if (!row) throw new Error('failed to insert custom pattern');

    return NextResponse.json({ pattern: customRowToSpec(row) });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}

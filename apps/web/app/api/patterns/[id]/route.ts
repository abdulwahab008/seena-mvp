import { NextResponse } from 'next/server';
import { z } from 'zod';
import { and, eq } from 'drizzle-orm';
import { Board, Format, PatternSection } from '@seena/shared';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { customRowToSpec } from '@/lib/patterns/resolver';

const PatchBody = z.object({
  name: z.string().min(1).max(120).optional(),
  format: Format.optional(),
  board: Board.optional(),
  grade: z.number().int().min(1).max(14).nullable().optional(),
  subject: z.string().min(1).max(80).nullable().optional(),
  totalMarks: z.number().int().positive().optional(),
  sections: z.array(PatternSection).min(1).optional(),
  notes: z.string().max(2000).nullable().optional(),
  isDefault: z.boolean().optional(),
});

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id } = await params;
    const [row] = await db
      .select()
      .from(schema.customPatterns)
      .where(
        and(
          eq(schema.customPatterns.id, id),
          eq(schema.customPatterns.orgId, orgId),
          eq(schema.customPatterns.archived, false),
        ),
      );
    if (!row) return NextResponse.json({ error: 'not found' }, { status: 404 });
    return NextResponse.json({ pattern: customRowToSpec(row) });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 401 });
  }
}

export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id } = await params;
    const body = PatchBody.parse(await req.json());

    const [row] = await db
      .update(schema.customPatterns)
      .set({
        ...(body.name !== undefined ? { name: body.name } : {}),
        ...(body.format !== undefined ? { format: body.format } : {}),
        ...(body.board !== undefined ? { board: body.board } : {}),
        ...(body.grade !== undefined ? { grade: body.grade } : {}),
        ...(body.subject !== undefined ? { subject: body.subject } : {}),
        ...(body.totalMarks !== undefined ? { totalMarks: body.totalMarks } : {}),
        ...(body.sections !== undefined ? { sections: body.sections } : {}),
        ...(body.notes !== undefined ? { notes: body.notes } : {}),
        ...(body.isDefault !== undefined ? { isDefault: body.isDefault } : {}),
        updatedAt: new Date(),
      })
      .where(
        and(eq(schema.customPatterns.id, id), eq(schema.customPatterns.orgId, orgId)),
      )
      .returning();
    if (!row) return NextResponse.json({ error: 'not found' }, { status: 404 });
    return NextResponse.json({ pattern: customRowToSpec(row) });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}

export async function DELETE(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const { orgId } = await requireSession();
    const { id } = await params;
    const [row] = await db
      .update(schema.customPatterns)
      .set({ archived: true, updatedAt: new Date() })
      .where(
        and(eq(schema.customPatterns.id, id), eq(schema.customPatterns.orgId, orgId)),
      )
      .returning({ id: schema.customPatterns.id });
    if (!row) return NextResponse.json({ error: 'not found' }, { status: 404 });
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 400 });
  }
}

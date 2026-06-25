import { NextResponse } from 'next/server';
import { eq } from 'drizzle-orm';
import { db, schema } from '@/lib/db';
import { requireSession } from '@/lib/auth';
import { deleteOrgStorage } from '@/lib/storage';
import { index } from '@/lib/pinecone';
import { apiError } from '@/lib/http';

export async function DELETE() {
  try {
    const { orgId, role } = await requireSession();
    if (role !== 'admin') {
      return NextResponse.json(
        { error: 'Only an admin can delete the organization.' },
        { status: 403 },
      );
    }

    // Delete the org's Pinecone namespaces (collected from its chunkings).
    try {
      const namespaces = await db
        .selectDistinct({ namespace: schema.chunkings.namespace })
        .from(schema.chunkings)
        .where(eq(schema.chunkings.orgId, orgId));
      const ix = index();
      for (const n of namespaces) {
        try {
          await ix.namespace(n.namespace).deleteAll();
        } catch (e) {
          console.warn(`pinecone deleteAll failed for ${n.namespace} (non-fatal)`, e);
        }
      }
    } catch (e) {
      console.warn('pinecone namespace cleanup failed (non-fatal)', e);
    }

    // Delete all storage objects under the org prefix.
    try {
      await deleteOrgStorage(orgId);
    } catch (e) {
      console.warn('org storage delete failed (non-fatal)', e);
    }

    // Cascade-delete the org and every row that references it.
    await db.delete(schema.organizations).where(eq(schema.organizations.id, orgId));

    return NextResponse.json({ ok: true });
  } catch (e) {
    return apiError(e);
  }
}

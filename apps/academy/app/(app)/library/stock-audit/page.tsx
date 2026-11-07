import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { AuditDesk } from './audit-desk';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'librarian'];

export default async function StockAuditPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  return (
    <>
      <PageHeader
        title="Shelf stock audit"
        description="Scan every book on the shelves (one barcode per line). The audit lists copies the register says are on the shelf but were not scanned, and scanned copies the register says are out."
      />
      <AuditDesk campusId={campus.id} />
    </>
  );
}

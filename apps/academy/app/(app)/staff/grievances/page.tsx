import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { PageHeader } from '@/components/ui/page-header';
import { GrievanceList, RaiseForm } from './grievance-forms';

export const dynamic = 'force-dynamic';

const HANDLERS = ['super_admin', 'owner', 'hr_manager'];

export default async function GrievancesPage() {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const handler = HANDLERS.includes(actor.role);

  const supabase = await supabaseServer();
  const { data: grievances } = await supabase
    .from('staff_grievance')
    .select('id, category, subject, description, status, resolution, created_at, raised_by')
    .order('created_at', { ascending: false })
    .limit(200);

  const mine = (grievances ?? []).filter((g) => g.raised_by === actor.userId);
  const others = (grievances ?? []).filter((g) => g.raised_by !== actor.userId);

  return (
    <>
      <PageHeader
        title="Grievances"
        description={handler ? 'Grievances raised by staff. Only HR and the owner see them; principals do not.' : 'Raise a concern with HR in confidence. Only HR and the owner can read it; your principal cannot.'}
      />
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <div className="space-y-6">
          {handler && <GrievanceList title="Raised by staff" grievances={others} canHandle />}
          <GrievanceList title="Raised by you" grievances={mine} canHandle={false} />
        </div>
        <RaiseForm />
      </div>
    </>
  );
}

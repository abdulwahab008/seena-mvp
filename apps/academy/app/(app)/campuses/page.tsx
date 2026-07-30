import { supabaseServer } from '@/lib/supabase/server';
import { CampusList } from './campus-list';
import { CreateCampusForm } from './create-campus-form';

export default async function CampusesPage() {
  const supabase = await supabaseServer();
  // No tenant_id filter here — RLS (campus_tenant_scope) already restricts
  // this to the signed-in user's own tenant.
  const { data: campuses } = await supabase
    .from('campus')
    .select('id, code, name, city, status')
    .order('code');

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Campuses</h1>
        <p className="text-sm text-muted-foreground">FR-A02 — add, list and archive your campuses.</p>
      </div>
      <CreateCampusForm />
      <CampusList campuses={campuses ?? []} />
    </div>
  );
}

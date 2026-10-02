import { supabaseServer } from '@/lib/supabase/server';
import { SubstitutionBoard } from './substitution-board';

export default async function SubstitutionsPage() {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Substitutions</h1>
        <p className="text-sm text-muted-foreground">FR-D13 — cover an absent teacher&apos;s periods with eligible free teachers, one screen.</p>
      </div>
      {!campusId ? <p className="text-sm text-muted-foreground">No active campus found.</p> : <SubstitutionBoard campusId={campusId} />}
    </div>
  );
}

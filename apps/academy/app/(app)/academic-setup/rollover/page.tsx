import { supabaseServer } from '@/lib/supabase/server';
import { RolloverForm } from './rollover-form';

export default async function RolloverPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }] = await Promise.all([
    supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Session rollover</h1>
        <p className="text-sm text-muted-foreground">
          FR-E11 — clone last session&apos;s sections, curriculum maps and teacher allocations into a new one. Enrolments and
          timetables are never cloned.
        </p>
      </div>
      <RolloverForm campuses={campuses ?? []} sessions={sessions ?? []} />
    </div>
  );
}

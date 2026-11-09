import { supabaseServer } from '@/lib/supabase/server';
import { LookupList } from './lookup-list';
import type { LookupKind } from './schema';

export const dynamic = 'force-dynamic';

const LISTS: { kind: LookupKind; title: string; description: string }[] = [
  { kind: 'category', title: 'Student categories', description: 'Orphan, staff child, hafiz and similar groups a student can belong to.' },
  { kind: 'region', title: 'Regions and areas', description: 'Where students live, for transport planning and reports.' },
  { kind: 'profession', title: 'Parent professions', description: 'Chosen on each guardian.' },
  { kind: 'school', title: 'Nearby schools', description: 'Schools students join from, chosen as a student’s previous school.' },
];

export default async function StudentListsPage() {
  const supabase = await supabaseServer();
  const { data } = await supabase.from('student_lookup').select('id, kind, name, area, is_active').order('is_active', { ascending: false }).order('name');
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Student lists</h1>
        <p className="text-sm text-muted-foreground">The choices offered on the student and guardian record. Deactivating an entry hides it from new choices; students who already have it keep it.</p>
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        {LISTS.map((l) => (
          <LookupList key={l.kind} {...l} entries={(data ?? []).filter((e) => e.kind === l.kind)} />
        ))}
      </div>
    </div>
  );
}

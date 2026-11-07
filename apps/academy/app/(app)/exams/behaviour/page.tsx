import { supabaseServer } from '@/lib/supabase/server';
import { loadTermSection, TermSectionForm } from '@/lib/exams/term-section';
import { BehaviourGrid, SetupTraitsButton } from './behaviour-grid';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function BehaviourPage({ searchParams }: { searchParams: Promise<{ section?: string; term?: string }> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const picked = await loadTermSection(supabase, sp);
  const { sectionId, termId } = picked;

  const [{ data: traits }, { data: enrolments }, { data: ratings }] = await Promise.all([
    supabase.from('behaviour_trait').select('id, name').eq('is_active', true).order('sort_order'),
    sectionId ? supabase.from('enrolment').select('id, roll_no, student(name_en)').eq('section_id', sectionId).eq('status', 'active') : Promise.resolve({ data: [] }),
    termId ? supabase.from('behaviour_rating').select('enrolment_id, trait_id, rating').eq('exam_term_id', termId) : Promise.resolve({ data: [] }),
  ]);
  const students = (enrolments ?? [])
    .map((e) => ({ id: e.id, rollNo: e.roll_no, name: one(e.student)?.name_en ?? '' }))
    .sort((a, b) => (a.rollNo ?? 9999) - (b.rollNo ?? 9999) || a.name.localeCompare(b.name));
  const initial = Object.fromEntries((ratings ?? []).map((r) => [`${r.enrolment_id}:${r.trait_id}`, r.rating]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Behaviour ratings</h1>
        <p className="text-sm text-muted-foreground">
          Co-scholastic ratings for each term, A (excellent) to E (needs attention), on traits such as punctuality and discipline.
        </p>
      </div>
      {(traits ?? []).length === 0 ? (
        <SetupTraitsButton />
      ) : (
        <>
          <TermSectionForm {...picked} />
          {sectionId && termId && students.length > 0 ? (
            <BehaviourGrid key={`${sectionId}:${termId}`} termId={termId} traits={traits ?? []} students={students} initial={initial} />
          ) : (
            <p className="text-sm text-muted-foreground">No students in this section.</p>
          )}
        </>
      )}
    </div>
  );
}

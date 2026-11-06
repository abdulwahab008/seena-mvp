import { supabaseServer } from '@/lib/supabase/server';
import { RequirementForm } from './requirement-form';
import { RequirementList } from './requirement-list';
import { pickActiveCampus } from '@/lib/campus-context';

export default async function ChecklistPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code');
  const campusId = (await pickActiveCampus(campuses))?.id;

  const [{ data: classLevels }, { data: requirements }] = await Promise.all([
    supabase.from('class_level').select('id, name_en, ordinal').eq('is_active', true).order('ordinal'),
    campusId
      ? supabase
          .from('admission_document_requirement')
          .select('id, doc_type, min_class_ordinal, max_class_ordinal, is_mandatory, min_count')
          .eq('campus_id', campusId)
          .is('effective_to', null)
          .order('doc_type')
      : Promise.resolve({ data: [] as never[] }),
  ]);

  const classLabel = (ordinal: number) => classLevels?.find((c) => c.ordinal === ordinal)?.name_en ?? `ordinal ${ordinal}`;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Document checklist</h1>
        <p className="text-sm text-muted-foreground">
          Which documents are mandatory for which classes, effective-dated so an already-submitted application is never
          retroactively re-flagged.
        </p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : (
        <>
          <RequirementForm campusId={campusId} classLevels={classLevels ?? []} />
          <RequirementList requirements={requirements ?? []} classLabel={classLabel} />
        </>
      )}
    </div>
  );
}

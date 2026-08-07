import { supabaseServer } from '@/lib/supabase/server';
import { CreateVersionForm } from './create-version-form';
import { TimetableGrid, type SlotRow } from './timetable-grid';

export default async function TimetablePage({ searchParams }: { searchParams: Promise<{ version?: string; section?: string }> }) {
  const { version: versionParam, section: sectionParam } = await searchParams;
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const { data: sessions } = campusId
    ? await supabase.from('academic_session').select('id').eq('is_current', true).limit(1)
    : { data: [] as never[] };
  const sessionId = sessions?.[0]?.id;

  const { data: versions } = campusId && sessionId
    ? await supabase
        .from('timetable_version')
        .select('id, name, shift, status')
        .eq('campus_id', campusId)
        .eq('session_id', sessionId)
        .order('created_at', { ascending: false })
    : { data: [] as never[] };

  const versionId = versionParam ?? versions?.[0]?.id;
  const selectedVersion = versions?.find((v) => v.id === versionId);

  const { data: sections } = campusId && sessionId
    ? await supabase
        .from('class_section')
        .select('id, name, class_level_id, class_level:class_level_id(name_en, code)')
        .eq('campus_id', campusId)
        .eq('session_id', sessionId)
        .eq('is_active', true)
        .order('name')
    : { data: [] as never[] };

  const sectionId = sectionParam ?? sections?.[0]?.id;

  const { data: subjects } = await supabase.from('subject').select('id, code, name_en').eq('is_active', true).order('name_en');
  const { data: rooms } = campusId ? await supabase.from('room').select('id, code, name').eq('campus_id', campusId).eq('is_active', true).order('code') : { data: [] as never[] };
  const { data: staff } = await supabase
    .from('app_user')
    .select('user_id, full_name')
    .in('app_role', ['subject_teacher', 'class_teacher', 'head_of_department'])
    .order('full_name');

  const { data: slots } =
    versionId && sectionId
      ? await supabase
          .from('timetable_slot')
          .select('id, weekday, period_no, subject_id, staff_id, room_id, subject:subject_id(code, name_en), room:room_id(code)')
          .eq('timetable_version_id', versionId)
          .eq('section_id', sectionId)
      : { data: [] as never[] };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Timetable Builder</h1>
        <p className="text-sm text-muted-foreground">FR-F04 — assign subjects, teachers and rooms onto a draft timetable, one section at a time.</p>
      </div>
      {!campusId || !sessionId ? (
        <p className="text-sm text-muted-foreground">No active campus or session found.</p>
      ) : (
        <>
          <CreateVersionForm campusId={campusId} sessionId={sessionId} />

          {!versions || versions.length === 0 ? (
            <p className="text-sm text-muted-foreground">No draft timetable versions yet — create one above.</p>
          ) : (
            <TimetableGrid
              versions={versions}
              selectedVersionId={versionId!}
              sections={(sections ?? []) as never[]}
              selectedSectionId={sectionId ?? null}
              subjects={subjects ?? []}
              rooms={rooms ?? []}
              staff={staff ?? []}
              slots={(slots ?? []) as unknown as SlotRow[]}
              isDraft={selectedVersion?.status === 'DRAFT'}
            />
          )}
        </>
      )}
    </div>
  );
}

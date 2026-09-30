import { supabaseServer } from '@/lib/supabase/server';
import { ClassesSectionsView } from './classes-sections-view';

export const dynamic = 'force-dynamic';

export default async function ClassesSectionsPage() {
  const supabase = await supabaseServer();

  // 1. Fetch campus and active sessions
  const { data: campuses } = await supabase
    .from('campus')
    .select('id, name, code')
    .eq('status', 'active')
    .order('code');

  const campus = campuses?.[0];

  const { data: sessions } = campus
    ? await supabase
        .from('academic_session')
        .select('id, name, is_current')
        .or(`campus_id.eq.${campus.id},campus_id.is.null`)
        .order('starts_on', { ascending: false })
    : { data: [] };

  const currentSession = sessions?.find((s) => s.is_current) ?? sessions?.[0];

  // 2. Fetch class levels in academic sequence
  const { data: classLevels } = await supabase
    .from('class_level')
    .select('id, name_en, name_ur, code, ordinal')
    .eq('is_active', true)
    .order('ordinal');

  // 3. Fetch active sections for this campus and session
  const { data: sections } = campus && currentSession
    ? await supabase
        .from('class_section')
        .select('id, name, capacity, medium, shift, is_active, class_level_id, campus_id, session_id')
        .eq('campus_id', campus.id)
        .eq('session_id', currentSession.id)
        .eq('is_active', true)
        .order('name')
    : { data: [] };

  // 4. Fetch enrolments to calculate occupancy per section
  const { data: enrolments } = campus && currentSession
    ? await supabase
        .from('enrolment')
        .select('section_id')
        .eq('campus_id', campus.id)
        .eq('session_id', currentSession.id)
        .eq('status', 'active')
    : { data: [] };

  const studentCountMap: Record<string, number> = {};
  (enrolments ?? []).forEach((e) => {
    if (e.section_id) {
      studentCountMap[e.section_id] = (studentCountMap[e.section_id] ?? 0) + 1;
    }
  });

  // 5. Fetch assigned class teachers
  const { data: classTeacherRows } = await supabase
    .from('section_class_teacher')
    .select('section_id, staff_id, effective_from')
    .is('effective_to', null);

  const teacherAssignmentMap: Record<string, string> = {};
  (classTeacherRows ?? []).forEach((row) => {
    if (row.staff_id) {
      teacherAssignmentMap[row.section_id] = row.staff_id;
    }
  });

  // 6. Fetch teaching staff for assignment dropdown
  const { data: staffList } = await supabase
    .from('app_user')
    .select('user_id, full_name, app_role')
    .in('app_role', ['subject_teacher', 'class_teacher', 'head_of_department', 'principal'])
    .order('full_name');

  return (
    <ClassesSectionsView
      campus={campus ?? null}
      campuses={campuses ?? []}
      currentSession={currentSession ?? null}
      sessions={sessions ?? []}
      classLevels={classLevels ?? []}
      sections={sections ?? []}
      studentCountMap={studentCountMap}
      teacherAssignmentMap={teacherAssignmentMap}
      staffList={staffList ?? []}
    />
  );
}

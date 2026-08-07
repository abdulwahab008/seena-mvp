import { supabaseServer } from '@/lib/supabase/server';
import { CreateHomeworkForm } from './create-homework-form';
import { HomeworkList } from './homework-list';

const ADMIN_ROLES = ['super_admin', 'owner', 'principal'];

export default async function HomeworkPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const isAdmin = !!appUser && ADMIN_ROLES.includes(appUser.app_role);

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  type Assignment = { sectionId: string; sectionLabel: string; subjectId: string; subjectLabel: string };
  let assignments: Assignment[] = [];

  if (campusId) {
    if (isAdmin) {
      const [{ data: sections }, { data: subjects }] = await Promise.all([
        supabase.from('class_section').select('id, name, class_level(name_en)').eq('campus_id', campusId).eq('is_active', true),
        supabase.from('subject').select('id, name_en').eq('is_active', true),
      ]);
      assignments = (sections ?? []).flatMap((s) => {
        const level = Array.isArray(s.class_level) ? s.class_level[0] : s.class_level;
        return (subjects ?? []).map((subj) => ({
          sectionId: s.id,
          sectionLabel: `${level?.name_en ?? ''} · ${s.name}`,
          subjectId: subj.id,
          subjectLabel: subj.name_en,
        }));
      });
    } else {
      // Listed for convenience only — create_homework()'s own validity @>
      // p_assigned_date check is the real, re-validated authorisation
      // boundary, so this list doesn't need to duplicate its date-range
      // logic (a teacher whose assignment lapsed sees a stale option that
      // the RPC would still correctly reject).
      const { data } = await supabase
        .from('section_subject_teacher')
        .select('section_id, subject_id, class_section(name, class_level(name_en)), subject(name_en)')
        .eq('staff_id', user!.id);
      assignments = (data ?? [])
        .map((r) => {
          const section = Array.isArray(r.class_section) ? r.class_section[0] : r.class_section;
          const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
          const subject = Array.isArray(r.subject) ? r.subject[0] : r.subject;
          if (!section || !subject) return null;
          return {
            sectionId: r.section_id,
            sectionLabel: `${level?.name_en ?? ''} · ${section.name}`,
            subjectId: r.subject_id,
            subjectLabel: subject.name_en,
          };
        })
        .filter((a): a is Assignment => !!a);
    }
  }

  const { data: homeworkRows } = campusId
    ? await supabase
        .from('homework')
        .select('id, title, status, assigned_date, due_date, class_section:section_id(name, class_level(name_en)), subject:subject_id(name_en)')
        .eq('campus_id', campusId)
        .order('due_date', { ascending: false })
        .limit(50)
    : { data: [] as never[] };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Homework</h1>
        <p className="text-sm text-muted-foreground">FR-H01 — publish a homework assignment to a section you teach.</p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : assignments.length === 0 ? (
        <p className="text-sm text-muted-foreground">No section/subject is assigned to you as a subject teacher.</p>
      ) : (
        <CreateHomeworkForm assignments={assignments} />
      )}
      <HomeworkList
        rows={(homeworkRows ?? []).map((h) => {
          const section = Array.isArray(h.class_section) ? h.class_section[0] : h.class_section;
          const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
          const subject = Array.isArray(h.subject) ? h.subject[0] : h.subject;
          return {
            id: h.id,
            title: h.title,
            status: h.status,
            assignedDate: h.assigned_date,
            dueDate: h.due_date,
            sectionLabel: `${level?.name_en ?? ''} · ${section?.name ?? ''}`,
            subjectLabel: subject?.name_en ?? '',
          };
        })}
      />
    </div>
  );
}

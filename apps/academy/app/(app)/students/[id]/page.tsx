import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { GuardianForm } from './guardian-form';
import { GuardianList } from './guardian-list';
import { EnrolForm } from './enrol-form';

// supabase-js types every embedded to-one relation as a possible array —
// the FK is unique per enrolment/section row, so it's really ever 0 or 1.
function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function StudentDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();

  const { data: student } = await supabase
    .from('student')
    .select('id, name_en, name_ur, gr_number, dob, gender, campus_id, status')
    .eq('id', id)
    .maybeSingle();
  if (!student) notFound();

  const [{ data: enrolment }, { data: sections }, { data: guardianLinks }] = await Promise.all([
    supabase
      .from('enrolment')
      .select('id, roll_no, class_section(name, class_level(name_en))')
      .eq('student_id', id)
      .eq('status', 'active')
      .maybeSingle(),
    supabase.from('class_section').select('id, name, class_level(name_en)').eq('campus_id', student.campus_id).eq('is_active', true),
    supabase
      .from('student_guardian')
      .select('guardian_id, relationship, is_primary, receives_billing, may_collect_child, guardian(name_en, phone_e164, cnic)')
      .eq('student_id', id)
      .is('to_date', null),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">{student.name_en}</h1>
        <p className="text-sm text-muted-foreground">
          GR {student.gr_number} · {student.gender} · DOB {student.dob} · {student.status}
        </p>
      </div>

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Enrolment</h2>
        {(() => {
          const section = enrolment ? one(enrolment.class_section) : null;
          const classLevel = section ? one(section.class_level) : null;
          return section && classLevel ? (
            <p data-testid="student-enrolment" className="text-sm">
              {classLevel.name_en} · Section {section.name} · Roll {enrolment!.roll_no ?? '—'}
            </p>
          ) : (
            <EnrolForm studentId={student.id} sections={sections ?? []} />
          );
        })()}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-medium">Guardians</h2>
        <GuardianList links={guardianLinks ?? []} />
        <GuardianForm studentId={student.id} />
      </section>
    </div>
  );
}

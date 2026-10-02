import { Metadata } from 'next';
import { supabaseServer } from '@/lib/supabase/server';
import { DepartmentsView, type DepartmentItem, type UnassignedStaffItem } from './departments-view';

export const metadata: Metadata = {
  title: 'Academic Departments — Seena Academy',
};

export const dynamic = 'force-dynamic';

export default async function DepartmentsPage() {
  const supabase = await supabaseServer();

  // 1. Fetch departments
  const { data: deptRows, error: deptError } = await supabase
    .from('department')
    .select('id, code, name_en, name_ur')
    .order('code', { ascending: true });

  if (deptError) {
    console.error('Error fetching departments:', deptError);
  }

  // 2. Fetch active staff with their department assignments
  const { data: staffRows, error: staffError } = await supabase
    .from('staff')
    .select('id, employee_code, full_name, department_id')
    .eq('employment_status', 'active')
    .order('full_name', { ascending: true });

  if (staffError) {
    console.error('Error fetching staff for departments:', staffError);
  }

  const staffList = staffRows ?? [];

  // 3. Map staff to departments
  const departments: DepartmentItem[] = (deptRows ?? []).map((d) => {
    const assignedTeachers = staffList
      .filter((s) => s.department_id === d.id)
      .map((s) => ({
        id: s.id,
        employee_code: s.employee_code,
        full_name: s.full_name,
      }));

    return {
      id: d.id,
      code: d.code,
      name_en: d.name_en,
      name_ur: d.name_ur,
      teacherCount: assignedTeachers.length,
      teachers: assignedTeachers,
    };
  });

  // 4. Identify unassigned staff
  const unassignedStaff: UnassignedStaffItem[] = staffList
    .filter((s) => !s.department_id)
    .map((s) => ({
      id: s.id,
      employee_code: s.employee_code,
      full_name: s.full_name,
    }));

  return (
    <div className="space-y-6">
      <DepartmentsView departments={departments} unassignedStaff={unassignedStaff} />
    </div>
  );
}

import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ManagerForm } from './manager-form';

export const dynamic = 'force-dynamic';

const EDIT_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager'];
const NO_DEPARTMENT = 'No department';

type Person = { id: string; name: string; code: string; designation: string | null; department: string | null; managerId: string | null };

function Branch({ person, reports }: { person: Person; reports: Map<string, Person[]> }) {
  const children = reports.get(person.id) ?? [];
  return (
    <li className="relative pl-5 before:absolute before:left-0 before:top-5 before:h-px before:w-4 before:bg-border" data-testid="org-node">
      <div className="inline-block rounded-md border bg-card px-3 py-2 text-sm shadow-xs">
        <span className="font-medium">{person.name}</span>
        <span className="block text-xs text-muted-foreground">
          {person.designation ?? 'No designation'} · {person.code}
        </span>
      </div>
      {children.length > 0 && (
        <ul className="ml-4 mt-2 space-y-2 border-l">
          {children.map((c) => (
            <Branch key={c.id} person={c} reports={reports} />
          ))}
        </ul>
      )}
    </li>
  );
}

export default async function OrgChartPage() {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from('staff')
    .select('id, full_name, employee_code, reports_to_staff_id, designation:designation_id(name_en), department:department_id(name_en)')
    .eq('employment_status', 'active')
    .order('full_name');

  const people: Person[] = (data ?? []).map((s) => ({
    id: s.id,
    name: s.full_name,
    code: s.employee_code,
    designation: one(s.designation)?.name_en ?? null,
    department: one(s.department)?.name_en ?? null,
    managerId: s.reports_to_staff_id,
  }));
  const visible = new Set(people.map((p) => p.id));
  const reports = new Map<string, Person[]>();
  const byDepartment = new Map<string, Person[]>();
  for (const p of people) {
    if (p.managerId && visible.has(p.managerId)) {
      reports.set(p.managerId, [...(reports.get(p.managerId) ?? []), p]);
    } else {
      const dept = p.department ?? NO_DEPARTMENT;
      byDepartment.set(dept, [...(byDepartment.get(dept) ?? []), p]);
    }
  }
  const departments = [...byDepartment.entries()].sort(([a], [b]) => (a === NO_DEPARTMENT ? 1 : b === NO_DEPARTMENT ? -1 : a.localeCompare(b)));

  return (
    <>
      <PageHeader title="Org chart" description="Who reports to whom. Staff with no manager set are listed under their department." />
      {EDIT_ROLES.includes(actor.role) && people.length > 0 && (
        <Card className="mb-6">
          <CardHeader>
            <CardTitle className="text-base">Set who someone reports to</CardTitle>
          </CardHeader>
          <CardContent>
            <ManagerForm staff={people.map((p) => ({ id: p.id, label: `${p.name} (${p.code})` }))} />
          </CardContent>
        </Card>
      )}
      {people.length === 0 ? (
        <EmptyState title="No staff yet" description="Add staff and they will appear here." />
      ) : (
        <div className="grid gap-6 lg:grid-cols-2">
          {departments.map(([dept, roots]) => (
            <Card key={dept} data-testid="org-department">
              <CardHeader>
                <CardTitle className="text-base">{dept}</CardTitle>
              </CardHeader>
              <CardContent className="overflow-x-auto">
                <ul className="space-y-2">
                  {roots.map((p) => (
                    <Branch key={p.id} person={p} reports={reports} />
                  ))}
                </ul>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </>
  );
}

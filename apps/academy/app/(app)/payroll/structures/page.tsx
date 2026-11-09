import { Metadata } from 'next';
import { supabaseServer } from '@/lib/supabase/server';
import { getEmployeeSalaryStructures, getStaffOptions } from '../actions';
import { StructuresDesk } from './structures-desk';

export const metadata: Metadata = {
  title: 'Employee Salary Structures | Payroll | Classora',
};

export default async function SalaryStructuresPage() {
  const supabase = await supabaseServer();
  const [structures, staffList, { data: payScales }] = await Promise.all([
    getEmployeeSalaryStructures(null),
    getStaffOptions(null),
    supabase.from('pay_scale').select('id, code, name').order('code'),
  ]);

  return (
    <div className="space-y-6">
      <StructuresDesk
        initialStructures={structures}
        staffList={staffList}
        payScales={payScales ?? []}
      />
    </div>
  );
}

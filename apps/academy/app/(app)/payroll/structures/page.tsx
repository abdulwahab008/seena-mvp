import { Metadata } from 'next';
import { getEmployeeSalaryStructures, getStaffOptions } from '../actions';
import { StructuresDesk } from './structures-desk';

export const metadata: Metadata = {
  title: 'Employee Salary Structures | Payroll | Seena Academy',
};

export default async function SalaryStructuresPage() {
  const [structures, staffList] = await Promise.all([
    getEmployeeSalaryStructures(null),
    getStaffOptions(null),
  ]);

  return (
    <div className="space-y-6">
      <StructuresDesk
        initialStructures={structures}
        staffList={staffList}
      />
    </div>
  );
}

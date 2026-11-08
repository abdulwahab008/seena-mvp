import { Metadata } from 'next';
import { getSalaryComponents } from '../actions';
import { ComponentsDesk } from './components-desk';

export const metadata: Metadata = {
  title: 'Salary Components | Payroll | Classora',
};

export default async function SalaryComponentsPage() {
  const components = await getSalaryComponents();

  return (
    <div className="space-y-6">
      <ComponentsDesk initialComponents={components} />
    </div>
  );
}

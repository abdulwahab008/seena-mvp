import { Metadata } from 'next';
import { getStaffLoans, getStaffOptions } from '../actions';
import { LoansDesk } from './loans-desk';

export const metadata: Metadata = {
  title: 'Staff Loans & Advances | Payroll | Seena Academy',
};

export default async function StaffLoansPage() {
  const [loans, staffList] = await Promise.all([
    getStaffLoans(null),
    getStaffOptions(null),
  ]);

  return (
    <div className="space-y-6">
      <LoansDesk initialLoans={loans} staffList={staffList} />
    </div>
  );
}

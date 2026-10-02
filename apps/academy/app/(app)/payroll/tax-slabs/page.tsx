import { Metadata } from 'next';
import { getTaxSlabs } from '../actions';
import { TaxSlabsDesk } from './tax-slabs-desk';

export const metadata: Metadata = {
  title: 'Tax Slabs & Simulator | Payroll | Seena Academy',
};

export default async function TaxSlabsPage() {
  const slabs = await getTaxSlabs();

  return (
    <div className="space-y-6">
      <TaxSlabsDesk initialSlabs={slabs} />
    </div>
  );
}

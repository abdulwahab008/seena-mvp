import { Metadata } from 'next';
import { getWhatsAppComplianceData } from './actions';
import { WhatsAppComplianceDesk } from './wa-compliance-desk';

export const metadata: Metadata = {
  title: 'WhatsApp Compliance & Session Desk | Communication | Seena Academy',
};

export default async function CommunicationWhatsAppPage() {
  const data = await getWhatsAppComplianceData();

  return (
    <div className="space-y-6">
      <WhatsAppComplianceDesk initialData={data} />
    </div>
  );
}

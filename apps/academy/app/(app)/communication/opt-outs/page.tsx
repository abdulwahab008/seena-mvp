import { fetchOptOutDashboardData } from './actions';
import { OptOutDesk } from './opt-out-desk';

export const metadata = {
  title: 'Opt-Outs & Suppression | Seena Academy',
};

export default async function CommunicationOptOutPage() {
  const data = await fetchOptOutDashboardData();

  return (
    <div className="container mx-auto p-6 max-w-7xl">
      <OptOutDesk
        optOuts={data.optOuts}
        inbounds={data.inbounds}
        audits={data.audits}
        role={data.role}
      />
    </div>
  );
}

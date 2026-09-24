import { getScheduledSendsData } from './actions';
import { ScheduledDesk } from './scheduled-desk';

export const metadata = {
  title: 'Scheduled Sends & Quiet Hours | Seena Academy',
  description: 'Scheduled campaign dispatcher, PTA quiet hours window (21:00 to 08:00 PKT), Ramadan overrides, and emergency bypass audit logging.',
};

export default async function ScheduledSendsPage() {
  const data = await getScheduledSendsData();

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      <ScheduledDesk initialData={data} />
    </div>
  );
}

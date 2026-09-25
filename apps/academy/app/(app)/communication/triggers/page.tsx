import { getTriggerRulesData } from './actions';
import { TriggerRulesDesk } from './trigger-rules-desk';

export const metadata = {
  title: 'Event-Triggered Message Rules | Seena Academy',
  description: 'Automated trigger rules for attendance absence notifications, overdue fee escalation, and decoupled outbox enqueueing.',
};

export default async function TriggerRulesPage() {
  const data = await getTriggerRulesData();

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      <TriggerRulesDesk initialData={data} />
    </div>
  );
}

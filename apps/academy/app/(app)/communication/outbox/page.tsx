import { Metadata } from 'next';
import { supabaseServer } from '@/lib/supabase/server';
import { getOutboxMessages, getOutboxStats } from '../actions';
import { OutboxDesk } from './outbox-desk';

export const metadata: Metadata = {
  title: 'Outbound Message Outbox | Communication | Seena Academy',
};

type SearchParams = { campus?: string; status?: string; channel?: string };

export default async function CommunicationOutboxPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const campusId = params.campus || null;

  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data: campuses } = await (supabase as any)
    .from('campus')
    .select('id, code, name')
    .order('name');

  const [messages, stats] = await Promise.all([
    getOutboxMessages({ campusId, status: params.status, channel: params.channel }),
    getOutboxStats(campusId),
  ]);

  return (
    <div className="space-y-6">
      <OutboxDesk
        initialMessages={messages}
        initialStats={stats}
        campuses={campuses || []}
        selectedCampusId={campusId}
      />
    </div>
  );
}

import { getChannelChains, getOptOuts, getRecentEscalations } from './actions';
import { FallbackChainsDesk } from './fallback-chains-desk';

export const metadata = {
  title: 'Channel Fallback Chains | Seena Academy',
  description: 'Multi-channel fallback routing, delivery timeout escalation, and opt-out suppression.',
};

export default async function FallbackChainsPage() {
  const [chains, optOuts, escalations] = await Promise.all([
    getChannelChains(),
    getOptOuts(),
    getRecentEscalations(),
  ]);

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      <FallbackChainsDesk
        initialChains={chains}
        initialOptOuts={optOuts}
        initialEscalations={escalations}
      />
    </div>
  );
}

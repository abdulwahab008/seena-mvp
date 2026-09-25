import { fetchWalletDashboardData } from './actions';
import { WalletDesk } from './wallet-desk';

export const metadata = {
  title: 'Messaging Wallet & Cost Ledger | Seena Academy',
};

export default async function CommunicationWalletPage() {
  const data = await fetchWalletDashboardData();

  return (
    <div className="container mx-auto p-6 max-w-7xl">
      <WalletDesk
        balancePaisa={data.balancePaisa}
        currency={data.currency}
        rateCards={data.rateCards}
        transactions={data.transactions}
        ledger={data.ledger}
        monthlySpend={data.monthlySpend}
        role={data.role}
      />
    </div>
  );
}

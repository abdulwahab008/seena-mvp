import { fetchDeliveryDashboardData } from './actions';
import { ReceiptsDesk } from './receipts-desk';

export const metadata = {
  title: 'Delivery Receipts | Seena Academy',
};

export default async function DeliveryReceiptsPage() {
  const data = await fetchDeliveryDashboardData();

  return (
    <div className="container mx-auto p-6 max-w-7xl">
      <ReceiptsDesk
        stats={data.stats}
        receipts={data.receipts}
        deadLetters={data.deadLetters}
        role={data.role}
      />
    </div>
  );
}

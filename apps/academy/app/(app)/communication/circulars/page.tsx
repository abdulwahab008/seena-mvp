import { fetchCircularsDashboardData } from './actions';
import { CircularDesk } from './circular-desk';

export const metadata = {
  title: 'Circular Publishing | Seena Academy',
};

export default async function CommunicationCircularsPage() {
  const data = await fetchCircularsDashboardData();

  return (
    <div className="container mx-auto p-6 max-w-7xl">
      <CircularDesk
        circulars={data.circulars as any}
        segments={data.segments as any}
        campuses={data.campuses as any}
      />
    </div>
  );
}

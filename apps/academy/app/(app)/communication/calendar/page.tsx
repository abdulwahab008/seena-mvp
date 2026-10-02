import { fetchCampusEventsDashboardData } from './actions';
import { CalendarDesk } from './calendar-desk';

export const metadata = {
  title: 'Campus Events & Calendar | Communication Desk',
};

export default async function CampusCalendarPage() {
  const data = await fetchCampusEventsDashboardData();

  return (
    <div className="space-y-6">
      <CalendarDesk
        events={data.events}
        campuses={data.campuses}
      />
    </div>
  );
}

import { getSegmentsData } from './actions';
import { DynamicSegmentDesk } from './segment-desk';

export const metadata = {
  title: 'Dynamic Audience Segments | Seena Academy',
  description: 'Audience rules engine for fee defaulters, morning absentee alerts, and audit snapshots.',
};

export default async function SegmentsPage() {
  const { segments, snapshots, stats, campusCutoffTime, campusId } = await getSegmentsData();

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      <DynamicSegmentDesk
        initialSegments={segments}
        initialSnapshots={snapshots}
        initialStats={stats}
        initialCutoffTime={campusCutoffTime}
        campusId={campusId}
      />
    </div>
  );
}

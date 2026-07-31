import { supabaseServer } from '@/lib/supabase/server';
import { CreateRoomForm } from './create-room-form';
import { RoomList } from './room-list';

export default async function RoomsPage() {
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const { data: rooms } = campusId
    ? await supabase
        .from('room')
        .select('id, code, name, room_type, capacity, block_label, is_active')
        .eq('campus_id', campusId)
        .order('code')
    : { data: [] as never[] };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Rooms</h1>
        <p className="text-sm text-muted-foreground">FR-E10 — the room registry a future timetable will schedule sections into.</p>
      </div>
      {!campusId ? (
        <p className="text-sm text-muted-foreground">No active campus found.</p>
      ) : (
        <>
          <CreateRoomForm campusId={campusId} />
          <RoomList rooms={rooms ?? []} />
        </>
      )}
    </div>
  );
}

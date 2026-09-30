import { supabaseServer } from '@/lib/supabase/server';
import { CreateRoomForm } from './create-room-form';
import { RoomList, type RoomRow } from './room-list';
import { Building, MapPin } from 'lucide-react';

export const dynamic = 'force-dynamic';

const MANAGE_ROLES = ['super_admin', 'owner', 'principal'];

export default async function RoomsPage({
  searchParams,
}: {
  searchParams?: Promise<{ campus_id?: string }> | { campus_id?: string };
}) {
  const resolvedParams = searchParams ? await Promise.resolve(searchParams) : {};
  const supabase = await supabaseServer();

  // Role check
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = user
    ? await supabase.from('app_user').select('app_role').eq('user_id', user.id).single()
    : { data: null };
  const canManage = MANAGE_ROLES.includes(appUser?.app_role ?? '');

  // Fetch active campuses
  const { data: campuses } = await supabase
    .from('campus')
    .select('id, code, name')
    .eq('status', 'active')
    .order('code');

  const selectedCampusId = resolvedParams.campus_id || campuses?.[0]?.id;
  const currentCampus = campuses?.find((c) => c.id === selectedCampusId) || campuses?.[0];

  // Fetch rooms for the campus
  const { data: rawRooms } = selectedCampusId
    ? await supabase
        .from('room')
        .select('id, code, name, room_type, capacity, block_label, is_active')
        .eq('campus_id', selectedCampusId)
        .order('code')
    : { data: [] as never[] };

  // Fetch section homeroom mappings for transparency
  const { data: sectionsWithRooms } = selectedCampusId
    ? await supabase
        .from('class_section')
        .select('id, name, home_room_id, class_level:class_level_id(name_en)')
        .eq('campus_id', selectedCampusId)
        .not('home_room_id', 'is', null)
    : { data: [] as never[] };

  // Fetch class levels for batch classroom generator
  const { data: classLevels } = await supabase
    .from('class_level')
    .select('id, code, name_en, ordinal')
    .eq('is_active', true)
    .order('ordinal');

  // Fetch all sections at this campus for batch classroom generator & linking
  const { data: allCampusSections } = selectedCampusId
    ? await supabase
        .from('class_section')
        .select('id, name, class_level_id, home_room_id')
        .eq('campus_id', selectedCampusId)
    : { data: [] as never[] };

  // Map home_room_id -> assigned section labels
  const homeroomMap = new Map<string, string[]>();
  if (sectionsWithRooms) {
    for (const sec of sectionsWithRooms) {
      if (sec.home_room_id) {
        const classLabel = (sec.class_level as { name_en: string } | null)?.name_en || 'Class';
        const fullLabel = `${classLabel} - ${sec.name}`;
        const existing = homeroomMap.get(sec.home_room_id) || [];
        existing.push(fullLabel);
        homeroomMap.set(sec.home_room_id, existing);
      }
    }
  }

  const rooms: RoomRow[] = (rawRooms || []).map((r) => ({
    id: r.id,
    code: r.code,
    name: r.name,
    room_type: r.room_type,
    capacity: r.capacity,
    block_label: r.block_label,
    is_active: r.is_active,
    assigned_sections: homeroomMap.get(r.id) || [],
  }));

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-2xl font-bold tracking-tight text-foreground">Rooms & Venues</h1>
            <span className="rounded-full bg-primary/10 px-2.5 py-0.5 text-xs font-semibold text-primary">
              {rooms.length} {rooms.length === 1 ? 'room' : 'rooms'}
            </span>
          </div>
          <p className="text-sm text-muted-foreground mt-0.5">
            Physical classrooms, specialized laboratories, and examination halls for timetable scheduling
          </p>
        </div>

        {/* Campus switcher if multiple campuses */}
        {campuses && campuses.length > 1 && (
          <div className="flex items-center gap-2 rounded-lg border border-border bg-card p-1 text-xs">
            <MapPin className="h-3.5 w-3.5 text-muted-foreground ml-2" />
            <span className="text-muted-foreground font-medium">Campus:</span>
            <div className="flex items-center gap-1">
              {campuses.map((c) => (
                <a
                  key={c.id}
                  href={`/academic-setup/rooms?campus_id=${c.id}`}
                  className={`rounded-md px-2.5 py-1 font-medium transition-colors ${
                    c.id === selectedCampusId
                      ? 'bg-primary text-primary-foreground shadow-xs'
                      : 'text-muted-foreground hover:text-foreground hover:bg-muted'
                  }`}
                >
                  {c.name} ({c.code})
                </a>
              ))}
            </div>
          </div>
        )}
      </div>

      {!selectedCampusId ? (
        <div className="rounded-xl border border-dashed p-8 text-center bg-card">
          <Building className="mx-auto h-8 w-8 text-muted-foreground/60" />
          <p className="text-sm font-medium text-foreground mt-2">No active campus found</p>
          <p className="text-xs text-muted-foreground mt-1">Please set up a campus first in Campus Management.</p>
        </div>
      ) : (
        <>
          {canManage && (
            <CreateRoomForm
              campusId={selectedCampusId}
              classes={classLevels || []}
              sections={allCampusSections || []}
            />
          )}
          <RoomList rooms={rooms} canManage={canManage} />
        </>
      )}
    </div>
  );
}

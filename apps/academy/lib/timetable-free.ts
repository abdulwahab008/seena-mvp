export type Busy = { staff_id: string | null; room_id: string | null };

// Who and what is not booked in a given period: every teacher and room on the
// campus minus those holding a slot in a published timetable at that time.
export function freeAt<T extends { id: string }, R extends { id: string }>(teachers: T[], rooms: R[], busy: Busy[]) {
  const busyStaff = new Set(busy.map((b) => b.staff_id).filter(Boolean));
  const busyRooms = new Set(busy.map((b) => b.room_id).filter(Boolean));
  return { teachers: teachers.filter((t) => !busyStaff.has(t.id)), rooms: rooms.filter((r) => !busyRooms.has(r.id)) };
}

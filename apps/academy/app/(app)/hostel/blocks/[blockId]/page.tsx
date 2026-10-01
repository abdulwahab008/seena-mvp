import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, HOSTEL_STAFF, loose } from '@/lib/transport/rpc';
import { addRoom, updateRoom } from '../../actions';

export const dynamic = 'force-dynamic';

type Room = { id: string; room_no: string; floor: number; room_type: string; bed_count: number; status: string };
type Bed = { room_id: string; bed_no: number; bed_code: string; status: string };

export default async function BlockPage({ params }: { params: Promise<{ blockId: string }> }) {
  const { blockId } = await params;
  const supabase = loose(await supabaseServer());
  const role = await currentRole(supabase);
  const { data: block } = await supabase.from('hostel_block').select('id, code, name, gender').eq('id', blockId).maybeSingle();
  if (!block) notFound();
  const { data: rooms } = await supabase.from('hostel_room').select('id, room_no, floor, room_type, bed_count, status').eq('block_id', blockId).order('floor').order('room_no');
  const { data: beds } = await supabase
    .from('hostel_bed')
    .select('room_id, bed_no, bed_code, status')
    .in('room_id', ((rooms ?? []) as Room[]).map((r) => r.id))
    .order('bed_no');
  const bedsByRoom = new Map<string, Bed[]>();
  for (const b of (beds ?? []) as Bed[]) bedsByRoom.set(b.room_id, [...(bedsByRoom.get(b.room_id) ?? []), b]);
  const canManage = HOSTEL_STAFF.includes(role);
  const types = ['single', 'double', 'triple', 'quad', 'dorm'].map((r) => ({ value: r, label: r }));

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-2xl font-semibold">
          {block.code} · {block.name} <Badge variant="outline">{block.gender === 'male' ? 'Boys' : 'Girls'}</Badge>
        </h1>
        <Link href="/hostel" className="rounded-md border px-3 py-1.5 text-sm">
          All blocks
        </Link>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Rooms and beds</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm" data-testid="room-list">
          {((rooms ?? []) as Room[]).map((r) => (
            <div key={r.id} className="space-y-2 border-b pb-3" data-testid="room-row">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium">
                  Room {r.room_no} · floor {r.floor} · {r.room_type} · {r.bed_count} beds
                </span>
                {r.status === 'out_of_service' && <Badge variant="warning">out of service</Badge>}
              </div>
              <div className="flex flex-wrap gap-1">
                {(bedsByRoom.get(r.id) ?? []).map((b) => (
                  <Badge key={b.bed_code} variant={b.status === 'occupied' ? 'primary' : b.status === 'retired' ? 'outline' : 'success'}>
                    {b.bed_code}
                    {b.status === 'retired' ? ' (retired)' : ''}
                  </Badge>
                ))}
              </div>
              {canManage && (
                <SpecForm
                  testId={`room-form-${r.room_no}`}
                  submitLabel="Update room"
                  action={updateRoom}
                  resetOnSuccess={false}
                  columns={4}
                  fields={[
                    { name: 'roomId', label: 'Room', type: 'hidden', defaultValue: r.id },
                    { name: 'bedCount', label: 'Beds', type: 'number', required: true, defaultValue: String(r.bed_count), min: '1' },
                    { name: 'roomType', label: 'Type', type: 'select', required: true, defaultValue: r.room_type, options: types },
                    { name: 'status', label: 'Status', type: 'select', required: true, defaultValue: r.status, options: [{ value: 'in_service', label: 'In service' }, { value: 'out_of_service', label: 'Out of service' }] },
                  ]}
                />
              )}
            </div>
          ))}
        </CardContent>
      </Card>
      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add a room</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="add-room-form"
              submitLabel="Add room"
              action={addRoom}
              columns={4}
              fields={[
                { name: 'blockId', label: 'Block', type: 'hidden', defaultValue: blockId },
                { name: 'roomNo', label: 'Room number', required: true },
                { name: 'bedCount', label: 'Beds', type: 'number', required: true, min: '1' },
                { name: 'roomType', label: 'Type', type: 'select', required: true, defaultValue: 'quad', options: types },
                { name: 'floor', label: 'Floor', type: 'number', min: '0' },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

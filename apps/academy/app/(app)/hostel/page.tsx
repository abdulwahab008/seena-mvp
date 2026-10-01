import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { currentRole, HOSTEL_STAFF, loose, pickCampus } from '@/lib/transport/rpc';
import { createBlock } from './actions';

export const dynamic = 'force-dynamic';

type Occ = { block_id: string; code: string; name: string; gender: string; rooms: number; beds_total: number; beds_occupied: number; beds_available: number; beds_out_of_service: number };

export default async function HostelPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const [{ data: occ }, { data: staff }] = await Promise.all([
    supabase.from('v_hostel_occupancy').select('block_id, code, name, gender, rooms, beds_total, beds_occupied, beds_available, beds_out_of_service').eq('campus_id', campus.id).order('code'),
    supabase.from('staff').select('id, full_name').eq('campus_id', campus.id).order('full_name'),
  ]);
  const blocks = (occ ?? []) as Occ[];
  const canManage = HOSTEL_STAFF.includes(role);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Hostel</h1>
        <p className="text-sm text-muted-foreground">FR-Q01 — blocks, rooms and individual beds. Gender belongs to the block; bed identities are permanent.</p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Blocks and occupancy</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="block-list">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Block</th>
                <th>Gender</th>
                <th>Rooms</th>
                <th>Beds</th>
                <th>Occupied</th>
                <th>Available</th>
                <th>Out of service</th>
              </tr>
            </thead>
            <tbody>
              {blocks.map((b) => (
                <tr key={b.block_id} className="border-t" data-testid="block-row">
                  <td className="py-1">
                    <Link className="font-medium hover:underline" href={`/hostel/blocks/${b.block_id}`}>
                      {b.code} · {b.name}
                    </Link>
                  </td>
                  <td>
                    <Badge variant="outline">{b.gender === 'male' ? 'Boys' : 'Girls'}</Badge>
                  </td>
                  <td>{b.rooms}</td>
                  <td data-testid="beds-total">{b.beds_total}</td>
                  <td>{b.beds_occupied}</td>
                  <td>{b.beds_available}</td>
                  <td>{b.beds_out_of_service}</td>
                </tr>
              ))}
              {blocks.length === 0 && (
                <tr>
                  <td colSpan={7} className="py-2 text-muted-foreground">
                    No hostel blocks yet.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add a block</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="block-form"
              submitLabel="Create block and beds"
              action={createBlock}
              columns={4}
              fields={[
                { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campus.id },
                { name: 'code', label: 'Block code', required: true, placeholder: 'IQ' },
                { name: 'name', label: 'Block name', required: true, placeholder: 'Iqbal Block' },
                { name: 'gender', label: 'Block is for', type: 'select', required: true, options: [{ value: 'male', label: 'Boys' }, { value: 'female', label: 'Girls' }] },
                { name: 'rooms', label: 'Rooms', type: 'number', required: true, min: '1' },
                { name: 'bedsPerRoom', label: 'Beds per room', type: 'number', required: true, min: '1' },
                { name: 'roomsPerFloor', label: 'Rooms per floor', type: 'number', min: '1', placeholder: '10' },
                { name: 'roomType', label: 'Room type', type: 'select', required: true, defaultValue: 'quad', options: ['single', 'double', 'triple', 'quad', 'dorm'].map((r) => ({ value: r, label: r })) },
                { name: 'wardenStaffId', label: 'Warden', type: 'select', options: ((staff ?? []) as { id: string; full_name: string }[]).map((s) => ({ value: s.id, label: s.full_name })) },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

'use client';

import { useState, useTransition, useMemo } from 'react';
import { toast } from 'sonner';
import { setRoomActive } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { EditRoomModal, type RoomItem } from './edit-room-modal';
import {
  Building,
  Building2,
  GraduationCap,
  FlaskConical,
  Laptop,
  BookOpen,
  Users,
  Search,
  Pencil,
  Power,
  ShieldCheck,
  Filter,
  Layers,
  MapPin,
} from 'lucide-react';

export type RoomRow = {
  id: string;
  code: string;
  name: string;
  room_type: string;
  capacity: number;
  block_label: string | null;
  is_active: boolean;
  assigned_sections?: string[];
};

function getRoomTypeIcon(type: string) {
  switch (type) {
    case 'CLASSROOM':
      return <GraduationCap className="h-3.5 w-3.5 text-blue-500" />;
    case 'SCIENCE_LAB':
      return <FlaskConical className="h-3.5 w-3.5 text-emerald-500" />;
    case 'COMPUTER_LAB':
      return <Laptop className="h-3.5 w-3.5 text-purple-500" />;
    case 'LIBRARY':
      return <BookOpen className="h-3.5 w-3.5 text-amber-500" />;
    case 'HALL':
      return <Building2 className="h-3.5 w-3.5 text-rose-500" />;
    default:
      return <Building className="h-3.5 w-3.5 text-slate-500" />;
  }
}

function ToggleActiveButton({ id, isActive, disabled = false }: { id: string; isActive: boolean; disabled?: boolean }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await setRoomActive(id, !isActive, { error: null }, new FormData());
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(isActive ? 'Room deactivated.' : 'Room activated.');
      }
    });
  };

  return (
    <Button
      type="button"
      size="sm"
      variant={isActive ? 'outline' : 'default'}
      disabled={pending || disabled}
      onClick={onClick}
      className={`h-8 gap-1.5 text-xs font-medium ${
        isActive
          ? 'text-muted-foreground hover:bg-destructive/10 hover:text-destructive border-border/80'
          : 'bg-primary text-primary-foreground hover:bg-primary/90'
      }`}
    >
      <Power className="h-3 w-3" />
      {isActive ? 'Deactivate' : 'Activate'}
    </Button>
  );
}

export function RoomList({
  rooms,
  canManage = true,
}: {
  rooms: RoomRow[];
  canManage?: boolean;
}) {
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState<string>('ALL');
  const [statusFilter, setStatusFilter] = useState<'ALL' | 'ACTIVE' | 'INACTIVE'>('ALL');
  const [editingRoom, setEditingRoom] = useState<RoomItem | null>(null);

  // Summary Metrics
  const stats = useMemo(() => {
    const total = rooms.length;
    const classrooms = rooms.filter((r) => r.room_type === 'CLASSROOM').length;
    const labs = rooms.filter((r) => r.room_type === 'SCIENCE_LAB' || r.room_type === 'COMPUTER_LAB').length;
    const totalCapacity = rooms.filter((r) => r.is_active).reduce((acc, r) => acc + (r.capacity || 0), 0);
    const inactive = rooms.filter((r) => !r.is_active).length;
    return { total, classrooms, labs, totalCapacity, inactive };
  }, [rooms]);

  // Filtered rooms
  const filteredRooms = useMemo(() => {
    return rooms.filter((r) => {
      // Search
      if (search.trim()) {
        const q = search.toLowerCase().trim();
        const matchCode = r.code.toLowerCase().includes(q);
        const matchName = r.name.toLowerCase().includes(q);
        const matchBlock = r.block_label?.toLowerCase().includes(q);
        if (!matchCode && !matchName && !matchBlock) return false;
      }
      // Type
      if (typeFilter !== 'ALL' && r.room_type !== typeFilter) {
        return false;
      }
      // Status
      if (statusFilter === 'ACTIVE' && !r.is_active) return false;
      if (statusFilter === 'INACTIVE' && r.is_active) return false;

      return true;
    });
  }, [rooms, search, typeFilter, statusFilter]);

  return (
    <div className="space-y-5">
      {/* Metric Cards */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
        <div className="rounded-xl border border-border/80 bg-card p-3.5 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium">Total Rooms</span>
            <Building2 className="h-4 w-4 text-primary" />
          </div>
          <div className="mt-2 text-2xl font-bold tracking-tight text-foreground">{stats.total}</div>
          <p className="text-[11px] text-muted-foreground mt-0.5">Physical facilities</p>
        </div>

        <div className="rounded-xl border border-border/80 bg-card p-3.5 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium">Classrooms</span>
            <GraduationCap className="h-4 w-4 text-blue-500" />
          </div>
          <div className="mt-2 text-2xl font-bold tracking-tight text-foreground">{stats.classrooms}</div>
          <p className="text-[11px] text-muted-foreground mt-0.5">Teaching rooms</p>
        </div>

        <div className="rounded-xl border border-border/80 bg-card p-3.5 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium">Specialized Labs</span>
            <FlaskConical className="h-4 w-4 text-emerald-500" />
          </div>
          <div className="mt-2 text-2xl font-bold tracking-tight text-foreground">{stats.labs}</div>
          <p className="text-[11px] text-muted-foreground mt-0.5">Science & IT labs</p>
        </div>

        <div className="rounded-xl border border-border/80 bg-card p-3.5 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium">Total Capacity</span>
            <Users className="h-4 w-4 text-purple-500" />
          </div>
          <div className="mt-2 text-2xl font-bold tracking-tight text-foreground">{stats.totalCapacity}</div>
          <p className="text-[11px] text-muted-foreground mt-0.5">Active student seats</p>
        </div>

        <div className="col-span-2 sm:col-span-1 rounded-xl border border-border/80 bg-card p-3.5 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium">Inactive</span>
            <Power className="h-4 w-4 text-amber-500" />
          </div>
          <div className="mt-2 text-2xl font-bold tracking-tight text-foreground">{stats.inactive}</div>
          <p className="text-[11px] text-muted-foreground mt-0.5">Under maintenance</p>
        </div>
      </div>

      {/* Search & Filters */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        {/* Search */}
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-3 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Search by code, name, block..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-9 pl-9 text-xs"
          />
        </div>

        {/* Room Type Filter Pills */}
        <div className="flex flex-wrap items-center gap-1.5 overflow-x-auto pb-1">
          {[
            { id: 'ALL', label: 'All' },
            { id: 'CLASSROOM', label: 'Classrooms' },
            { id: 'SCIENCE_LAB', label: 'Science' },
            { id: 'COMPUTER_LAB', label: 'Computer' },
            { id: 'LIBRARY', label: 'Library' },
            { id: 'HALL', label: 'Halls' },
          ].map((type) => (
            <button
              key={type.id}
              onClick={() => setTypeFilter(type.id)}
              className={`rounded-full px-3 py-1 text-xs font-medium transition-all ${
                typeFilter === type.id
                  ? 'bg-primary text-primary-foreground shadow-sm'
                  : 'bg-muted/60 text-muted-foreground hover:bg-muted hover:text-foreground'
              }`}
            >
              {type.label}
            </button>
          ))}

          {/* Status filter toggle */}
          <div className="ml-auto flex items-center rounded-lg border border-border/70 p-0.5 bg-muted/30">
            <button
              onClick={() => setStatusFilter('ALL')}
              className={`rounded-md px-2 py-0.5 text-[11px] font-medium transition-colors ${
                statusFilter === 'ALL' ? 'bg-background text-foreground shadow-xs' : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              All
            </button>
            <button
              onClick={() => setStatusFilter('ACTIVE')}
              className={`rounded-md px-2 py-0.5 text-[11px] font-medium transition-colors ${
                statusFilter === 'ACTIVE' ? 'bg-background text-emerald-600 font-semibold shadow-xs' : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              Active
            </button>
            <button
              onClick={() => setStatusFilter('INACTIVE')}
              className={`rounded-md px-2 py-0.5 text-[11px] font-medium transition-colors ${
                statusFilter === 'INACTIVE' ? 'bg-background text-amber-600 font-semibold shadow-xs' : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              Inactive
            </button>
          </div>
        </div>
      </div>

      {/* Room Cards / List */}
      {filteredRooms.length === 0 ? (
        <div className="rounded-xl border border-dashed border-border/80 p-8 text-center bg-card/30">
          <Building2 className="mx-auto h-8 w-8 text-muted-foreground/60" />
          <h3 className="mt-2 text-sm font-semibold text-foreground">No rooms found</h3>
          <p className="text-xs text-muted-foreground mt-1">
            {rooms.length === 0
              ? 'No rooms registered yet. Use the form above to register your first classroom or lab.'
              : 'Try changing your search keywords or filter selection.'}
          </p>
        </div>
      ) : (
        <div className="space-y-2.5">
          {filteredRooms.map((r) => (
            <Card
              key={r.id}
              data-testid={`room-row-${r.code}`}
              className={`transition-all hover:border-primary/40 hover:shadow-sm ${
                !r.is_active ? 'opacity-70 bg-muted/20 border-dashed' : 'bg-card'
              }`}
            >
              <CardContent className="flex flex-col sm:flex-row sm:items-center sm:justify-between p-4 gap-3">
                <div className="space-y-1.5 flex-1 min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-semibold text-foreground text-sm tracking-tight">
                      {r.name}
                    </span>
                    <span className="font-mono text-xs text-muted-foreground">({r.code})</span>

                    {/* Room Type badge */}
                    <span className="inline-flex items-center gap-1 rounded-md border border-border/70 bg-muted/40 px-2 py-0.5 text-[11px] font-medium text-foreground">
                      {getRoomTypeIcon(r.room_type)}
                      <span>{r.room_type.replace(/_/g, ' ')}</span>
                    </span>

                    {/* Block label badge */}
                    {r.block_label && (
                      <span className="inline-flex items-center gap-1 rounded-md border border-border/60 bg-background px-2 py-0.5 text-[11px] text-muted-foreground">
                        <MapPin className="h-3 w-3" />
                        {r.block_label}
                      </span>
                    )}

                    {/* Inactive badge (strictly preserves E2E test locator) */}
                    {!r.is_active && (
                      <span className="rounded-md border border-destructive/20 bg-destructive/10 px-2 py-0.5 text-[11px] font-medium text-destructive">
                        inactive
                      </span>
                    )}
                  </div>

                  <div className="flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
                    <span className="flex items-center gap-1 font-medium text-foreground/80">
                      <Users className="h-3.5 w-3.5 text-muted-foreground" />
                      capacity {r.capacity}
                    </span>

                    {r.assigned_sections && r.assigned_sections.length > 0 ? (
                      <span className="inline-flex items-center gap-1 text-[11px] font-medium text-primary bg-primary/10 px-2 py-0.5 rounded-full">
                        <GraduationCap className="h-3 w-3" />
                        Homeroom: {r.assigned_sections.join(', ')}
                      </span>
                    ) : (
                      <span className="text-[11px] text-muted-foreground/80 italic">
                        Shared facility / general scheduling
                      </span>
                    )}
                  </div>
                </div>

                {/* Actions */}
                {canManage && (
                  <div className="flex items-center gap-2 self-end sm:self-center">
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      onClick={() =>
                        setEditingRoom({
                          id: r.id,
                          code: r.code,
                          name: r.name,
                          room_type: r.room_type,
                          capacity: r.capacity,
                          block_label: r.block_label,
                          is_active: r.is_active,
                          assignedSections: r.assigned_sections,
                        })
                      }
                      className="h-8 gap-1.5 text-xs text-muted-foreground hover:text-foreground hover:border-primary/40"
                    >
                      <Pencil className="h-3 w-3" />
                      Edit
                    </Button>

                    <ToggleActiveButton id={r.id} isActive={r.is_active} />
                  </div>
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      {/* Edit Room Modal */}
      {editingRoom && (
        <EditRoomModal
          key={editingRoom.id}
          open={!!editingRoom}
          onClose={() => setEditingRoom(null)}
          room={editingRoom}
        />
      )}
    </div>
  );
}

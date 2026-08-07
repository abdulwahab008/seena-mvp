'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { upsertTimetableSlot, clearTimetableSlot, getSlotPrefill } from './actions';
import { upsertTimetableSlotSchema, type UpsertTimetableSlotInput } from '@/lib/validation';
import { TimetableRealtimeRefresher } from './timetable-realtime-refresher';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

const WEEKDAYS = [
  { value: 1, label: 'Monday' },
  { value: 2, label: 'Tuesday' },
  { value: 3, label: 'Wednesday' },
  { value: 4, label: 'Thursday' },
  { value: 5, label: 'Friday' },
  { value: 6, label: 'Saturday' },
];
const NONE = '__none__';

type Version = { id: string; name: string; shift: string; status: string };
type Section = { id: string; name: string; class_level: { name_en: string; code: string } | null };
type Subject = { id: string; code: string; name_en: string };
type Room = { id: string; code: string; name: string };
type Staff = { user_id: string; full_name: string };
export type SlotRow = {
  id: string;
  weekday: number;
  period_no: number;
  subject_id: string;
  staff_id: string | null;
  room_id: string | null;
  subject: { code: string; name_en: string } | null;
  room: { code: string } | null;
};

function VersionSectionPicker({
  versions,
  selectedVersionId,
  sections,
  selectedSectionId,
}: {
  versions: Version[];
  selectedVersionId: string;
  sections: Section[];
  selectedSectionId: string | null;
}) {
  const router = useRouter();

  return (
    <div className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4">
      <div className="space-y-1">
        <Label htmlFor="version-picker">Version</Label>
        <select
          id="version-picker"
          data-testid="version-picker"
          className="h-9 w-full rounded-md border px-3 text-sm"
          value={selectedVersionId}
          onChange={(e) => router.push(`/academic-setup/timetable?version=${e.target.value}${selectedSectionId ? `&section=${selectedSectionId}` : ''}`)}
        >
          {versions.map((v) => (
            <option key={v.id} value={v.id}>
              {v.name} ({v.shift}, {v.status})
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="section-picker">Section</Label>
        <select
          id="section-picker"
          data-testid="section-picker"
          className="h-9 w-full rounded-md border px-3 text-sm"
          value={selectedSectionId ?? ''}
          onChange={(e) => router.push(`/academic-setup/timetable?version=${selectedVersionId}&section=${e.target.value}`)}
        >
          {sections.map((s) => (
            <option key={s.id} value={s.id}>
              {s.class_level?.name_en ?? s.class_level?.code} · {s.name}
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}

function WriteSlotForm({
  versionId,
  sectionId,
  subjects,
  rooms,
  staff,
}: {
  versionId: string;
  sectionId: string;
  subjects: Subject[];
  rooms: Room[];
  staff: Staff[];
}) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    setValue,
    getValues,
    reset,
    formState: { errors },
  } = useForm<UpsertTimetableSlotInput>({
    resolver: zodResolver(upsertTimetableSlotSchema),
    defaultValues: { weekday: 1, periodNo: 1, subjectId: '', staffId: undefined, roomId: undefined },
  });

  const onSubjectChange = async (subjectId: string) => {
    setValue('subjectId', subjectId);
    if (!subjectId) return;
    // Prefill is async — if the user manually picks a teacher/room while
    // this fetch is still in flight, applying the fetched defaults
    // unconditionally on resolution would silently overwrite their
    // choice. Only apply a field if it's still untouched since this call
    // started.
    const staffBefore = getValues('staffId');
    const roomBefore = getValues('roomId');
    const prefill = await getSlotPrefill(sectionId, subjectId);
    if (getValues('staffId') === staffBefore) setValue('staffId', prefill?.staffId ?? undefined);
    if (getValues('roomId') === roomBefore) setValue('roomId', prefill?.roomId ?? undefined);
  };

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('weekday', String(values.weekday));
    fd.set('periodNo', String(values.periodNo));
    fd.set('subjectId', values.subjectId);
    if (values.staffId) fd.set('staffId', values.staffId);
    if (values.roomId) fd.set('roomId', values.roomId);

    startTransition(async () => {
      const result = await upsertTimetableSlot(versionId, sectionId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Slot saved.');
        reset({ weekday: values.weekday, periodNo: values.periodNo, subjectId: '', staffId: undefined, roomId: undefined });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" data-testid="write-slot-form" noValidate>
      <div className="space-y-1">
        <Label htmlFor="slot-weekday">Weekday</Label>
        <Controller
          control={control}
          name="weekday"
          render={({ field }) => (
            <Select value={String(field.value)} onValueChange={(v) => field.onChange(Number(v))}>
              <SelectTrigger data-testid="slot-weekday-trigger">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {WEEKDAYS.map((w) => (
                  <SelectItem key={w.value} value={String(w.value)}>
                    {w.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="slot-period">Period</Label>
        <Input id="slot-period" type="number" min={1} data-testid="slot-period-input" {...register('periodNo')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="slot-subject">Subject</Label>
        <Controller
          control={control}
          name="subjectId"
          render={({ field }) => (
            <Select value={field.value || NONE} onValueChange={(v) => onSubjectChange(v === NONE ? '' : v)}>
              <SelectTrigger data-testid="slot-subject-trigger">
                <SelectValue placeholder="Choose subject" />
              </SelectTrigger>
              <SelectContent>
                {subjects.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name_en} ({s.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.subjectId && <p className="text-xs text-destructive">{errors.subjectId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="slot-staff">Teacher (pre-filled, overridable)</Label>
        <Controller
          control={control}
          name="staffId"
          render={({ field }) => (
            <Select value={field.value || NONE} onValueChange={(v) => field.onChange(v === NONE ? undefined : v)}>
              <SelectTrigger data-testid="slot-staff-trigger">
                <SelectValue placeholder="None" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={NONE}>None</SelectItem>
                {staff.map((s) => (
                  <SelectItem key={s.user_id} value={s.user_id}>
                    {s.full_name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="slot-room">Room (pre-filled, overridable)</Label>
        <Controller
          control={control}
          name="roomId"
          render={({ field }) => (
            <Select value={field.value || NONE} onValueChange={(v) => field.onChange(v === NONE ? undefined : v)}>
              <SelectTrigger data-testid="slot-room-trigger">
                <SelectValue placeholder="None" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={NONE}>None</SelectItem>
                {rooms.map((r) => (
                  <SelectItem key={r.id} value={r.id}>
                    {r.name} ({r.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <Button type="submit" disabled={pending} data-testid="save-slot-button" className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Save slot'}
      </Button>
    </form>
  );
}

function ClearSlotButton({ versionId, sectionId, weekday, periodNo }: { versionId: string; sectionId: string; weekday: number; periodNo: number }) {
  const [pending, startTransition] = useTransition();
  const onClick = () => {
    startTransition(async () => {
      const result = await clearTimetableSlot(versionId, sectionId, weekday, periodNo, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Slot cleared.');
    });
  };
  return (
    <button
      type="button"
      disabled={pending}
      onClick={onClick}
      data-testid={`clear-slot-${weekday}-${periodNo}`}
      className="text-xs text-muted-foreground underline hover:text-destructive"
    >
      Clear
    </button>
  );
}

export function TimetableGrid({
  versions,
  selectedVersionId,
  sections,
  selectedSectionId,
  subjects,
  rooms,
  staff,
  slots,
  isDraft,
}: {
  versions: Version[];
  selectedVersionId: string;
  sections: Section[];
  selectedSectionId: string | null;
  subjects: Subject[];
  rooms: Room[];
  staff: Staff[];
  slots: SlotRow[];
  isDraft: boolean;
}) {
  const periods = Array.from(new Set([...Array.from({ length: 8 }, (_, i) => i + 1), ...slots.map((s) => s.period_no)])).sort((a, b) => a - b);
  const slotAt = (weekday: number, periodNo: number) => slots.find((s) => s.weekday === weekday && s.period_no === periodNo);

  return (
    <div className="space-y-4">
      <TimetableRealtimeRefresher versionId={selectedVersionId} />
      <VersionSectionPicker versions={versions} selectedVersionId={selectedVersionId} sections={sections} selectedSectionId={selectedSectionId} />

      {!selectedSectionId ? (
        <p className="text-sm text-muted-foreground">No sections found for this campus/session.</p>
      ) : !isDraft ? (
        <p data-testid="version-immutable-banner" className="rounded-md border border-amber-400 bg-amber-50 p-3 text-sm text-amber-900">
          This version is no longer a draft — the grid below is read-only.
        </p>
      ) : (
        <WriteSlotForm versionId={selectedVersionId} sectionId={selectedSectionId} subjects={subjects} rooms={rooms} staff={staff} />
      )}

      {selectedSectionId && (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50">
                <th className="p-2 text-left font-medium">Period</th>
                {WEEKDAYS.map((w) => (
                  <th key={w.value} className="p-2 text-left font-medium">
                    {w.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {periods.map((periodNo) => (
                <tr key={periodNo} className="border-b last:border-0">
                  <td className="p-2 font-medium text-muted-foreground">{periodNo}</td>
                  {WEEKDAYS.map((w) => {
                    const slot = slotAt(w.value, periodNo);
                    return (
                      <td key={w.value} data-testid={`grid-cell-${w.value}-${periodNo}`} className="p-2 align-top">
                        {slot ? (
                          <div className="space-y-0.5">
                            <p className="font-medium">{slot.subject?.code ?? '—'}</p>
                            {slot.room && <p className="text-xs text-muted-foreground">{slot.room.code}</p>}
                            {isDraft && (
                              <ClearSlotButton versionId={selectedVersionId} sectionId={selectedSectionId} weekday={w.value} periodNo={periodNo} />
                            )}
                          </div>
                        ) : (
                          <span className="text-xs text-muted-foreground">Free</span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

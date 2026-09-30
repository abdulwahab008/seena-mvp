'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { upsertTimetableSlot, clearTimetableSlot, getSlotPrefill, publishTimetable, cloneTimetableVersion, createParallelGroup } from './actions';
import { upsertTimetableSlotSchema, publishTimetableSchema, type UpsertTimetableSlotInput, type PublishTimetableInput } from '@/lib/validation';
import { TimetableRealtimeRefresher } from './timetable-realtime-refresher';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';

const WEEKDAYS = [
  { value: 1, label: 'Monday' },
  { value: 2, label: 'Tuesday' },
  { value: 3, label: 'Wednesday' },
  { value: 4, label: 'Thursday' },
  { value: 5, label: 'Friday' },
  { value: 6, label: 'Saturday' },
];
const NONE = '__none__';

type Version = {
  id: string;
  name: string;
  shift: string;
  status: string;
  version_no: number;
  effective_from: string | null;
  effective_to: string | null;
  warning_count: number;
};
type Section = { id: string; name: string; class_level: { name_en: string; code: string } | null };
type Subject = { id: string; code: string; name_en: string };
type Room = { id: string; code: string; name: string };
type Staff = { user_id: string; full_name: string };
export type RoomWarning = { room_id: string; weekday: number; period_no: number; total_students: number; room_capacity: number };
export type SlotRow = {
  id: string;
  weekday: number;
  period_no: number;
  subject_id: string;
  staff_id: string | null;
  room_id: string | null;
  elective_bucket: number | null;
  parallel_group_id: string | null;
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
  slots,
}: {
  versionId: string;
  sectionId: string;
  subjects: Subject[];
  rooms: Room[];
  staff: Staff[];
  slots: SlotRow[];
}) {
  const [pending, startTransition] = useTransition();
  const [needsOverride, setNeedsOverride] = useState(false);
  const [overrideReason, setOverrideReason] = useState('');
  const [isElective, setIsElective] = useState(false);
  const [electiveBucket, setElectiveBucket] = useState('');
  const {
    register,
    control,
    handleSubmit,
    setValue,
    getValues,
    watch,
    reset,
    formState: { errors },
  } = useForm<UpsertTimetableSlotInput>({
    resolver: zodResolver(upsertTimetableSlotSchema),
    defaultValues: { weekday: 1, periodNo: 1, subjectId: '', staffId: undefined, roomId: undefined },
  });

  const weekday = watch('weekday');
  const periodNo = watch('periodNo');
  // AC2: an elective block already started at this exact cell (by an
  // earlier save) is joined automatically — its own bucket is reused, and
  // a second "create" never happens for the same period.
  const existingGroup = slots.find((s) => s.weekday === weekday && s.period_no === Number(periodNo) && s.parallel_group_id);
  const effectiveIsElective = isElective || !!existingGroup;

  // Moving to a different cell drops the manual elective toggle — the
  // target cell's own existingGroup (if any) takes over from there.
  useEffect(() => {
    setIsElective(false);
    setElectiveBucket('');
  }, [weekday, periodNo]);

  // Prefill is async — if the user manually picks a teacher/room while
  // this fetch is still in flight, applying the fetched defaults
  // unconditionally on resolution would silently overwrite their choice.
  // Tracked as an explicit "did the user touch this field" flag rather
  // than a before/after value comparison — comparing values breaks the
  // moment the user's own pick happens to match whatever was already
  // there (e.g. re-selecting the same room for a second section), which
  // looks identical to "untouched" under a value diff.
  const staffTouchedRef = useRef(false);
  const roomTouchedRef = useRef(false);

  const onSubjectChange = async (subjectId: string) => {
    setValue('subjectId', subjectId);
    setNeedsOverride(false);
    setOverrideReason('');
    if (!subjectId) return;
    staffTouchedRef.current = false;
    roomTouchedRef.current = false;
    const prefill = await getSlotPrefill(sectionId, subjectId);
    if (!staffTouchedRef.current) setValue('staffId', prefill?.staffId ?? undefined);
    if (!roomTouchedRef.current) setValue('roomId', prefill?.roomId ?? undefined);
  };

  const onSubmit = handleSubmit((values) => {
    const bucket = existingGroup?.elective_bucket ?? Number(electiveBucket);

    startTransition(async () => {
      let groupId = existingGroup?.parallel_group_id ?? null;
      if (effectiveIsElective && !groupId) {
        const created = await createParallelGroup(versionId, sectionId, values.weekday, values.periodNo, bucket);
        if (created.error) {
          toast.error(created.error);
          return;
        }
        groupId = created.groupId;
      }

      const fd = new FormData();
      fd.set('weekday', String(values.weekday));
      fd.set('periodNo', String(values.periodNo));
      fd.set('subjectId', values.subjectId);
      if (values.staffId) fd.set('staffId', values.staffId);
      if (values.roomId) fd.set('roomId', values.roomId);
      if (needsOverride && overrideReason.trim()) fd.set('overrideReason', overrideReason.trim());
      if (effectiveIsElective && groupId) {
        fd.set('electiveBucket', String(bucket));
        fd.set('parallelGroupId', groupId);
      }

      const result = await upsertTimetableSlot(versionId, sectionId, { error: null }, fd);
      if (result.error === 'TEACH_SCOPE_VIOLATION') {
        setNeedsOverride(true);
        toast.error("This teacher isn't approved for this subject/grade. Supply a reason to override, or choose another teacher.");
      } else if (result.error) {
        toast.error(result.error);
      } else {
        toast.success('Slot saved.');
        setNeedsOverride(false);
        setOverrideReason('');
        setIsElective(false);
        setElectiveBucket('');
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
            <Select
              value={field.value || NONE}
              onValueChange={(v) => {
                staffTouchedRef.current = true;
                field.onChange(v === NONE ? undefined : v);
              }}
            >
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
            <Select
              value={field.value || NONE}
              onValueChange={(v) => {
                roomTouchedRef.current = true;
                field.onChange(v === NONE ? undefined : v);
              }}
            >
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
      <div className="col-span-full flex flex-wrap items-end gap-3 rounded-md border p-3">
        <div className="flex items-center gap-2">
          <input
            id="slot-is-elective"
            type="checkbox"
            data-testid="slot-elective-toggle"
            checked={effectiveIsElective}
            disabled={!!existingGroup}
            onChange={(e) => setIsElective(e.target.checked)}
          />
          <Label htmlFor="slot-is-elective">Parallel elective block</Label>
        </div>
        {effectiveIsElective && (
          <div className="space-y-1">
            <Label htmlFor="slot-elective-bucket">Bucket</Label>
            <Input
              id="slot-elective-bucket"
              type="number"
              min={1}
              data-testid="slot-elective-bucket-input"
              value={existingGroup ? String(existingGroup.elective_bucket) : electiveBucket}
              disabled={!!existingGroup}
              onChange={(e) => setElectiveBucket(e.target.value)}
            />
          </div>
        )}
      </div>
      {needsOverride && (
        <div className="col-span-full space-y-1 rounded-md border border-amber-400 bg-amber-50 p-3">
          <Label htmlFor="slot-override-reason" className="text-amber-900">
            This teacher isn&apos;t approved for this subject/grade. Give a reason to override, or change the teacher above.
          </Label>
          <Input
            id="slot-override-reason"
            data-testid="slot-override-reason-input"
            placeholder="e.g. temporary cover until replacement joins"
            value={overrideReason}
            onChange={(e) => setOverrideReason(e.target.value)}
          />
        </div>
      )}
      <Button type="submit" disabled={pending} data-testid="save-slot-button" className="col-span-full w-fit">
        {pending ? 'Saving…' : needsOverride ? 'Save with override' : 'Save slot'}
      </Button>
    </form>
  );
}

function PublishVersionForm({ versionId }: { versionId: string }) {
  const [pending, startTransition] = useTransition();
  const [needsOverride, setNeedsOverride] = useState(false);
  const [shortfallMessage, setShortfallMessage] = useState('');
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<PublishTimetableInput>({
    resolver: zodResolver(publishTimetableSchema),
    defaultValues: { effectiveFrom: '', overrideReason: '' },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('effectiveFrom', values.effectiveFrom);
    if (needsOverride && values.overrideReason?.trim()) fd.set('overrideReason', values.overrideReason.trim());

    startTransition(async () => {
      const result = await publishTimetable(versionId, { error: null }, fd);
      if (result.error?.startsWith('QUOTA_SHORTFALL')) {
        setNeedsOverride(true);
        setShortfallMessage(result.error.replace('QUOTA_SHORTFALL: ', ''));
        toast.error("This timetable doesn't yet deliver every subject's required periods.");
      } else if (result.error) {
        toast.error(result.error);
      } else {
        toast.success('Timetable published.');
        setNeedsOverride(false);
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3 rounded-lg border border-blue-300 bg-blue-50 p-4" data-testid="publish-version-form">
      <div className="space-y-1">
        <Label htmlFor="publish-effective-from">Effective from</Label>
        <Controller
          control={control}
          name="effectiveFrom"
          render={({ field }) => (
            <DatePicker
              id="publish-effective-from"
              name="effectiveFrom"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="Effective from"
              data-testid="publish-effective-from-input"
            />
          )}
        />
        {errors.effectiveFrom && <p className="text-xs text-destructive">{errors.effectiveFrom.message}</p>}
      </div>
      {needsOverride && (
        <div className="w-full space-y-1 rounded-md border border-amber-400 bg-amber-50 p-3">
          <p className="text-sm text-amber-900" data-testid="quota-shortfall-message">
            Short: {shortfallMessage}
          </p>
          <Label htmlFor="publish-override-reason" className="text-amber-900">
            Publish anyway — give a reason (at least 10 characters)
          </Label>
          <Input
            id="publish-override-reason"
            data-testid="publish-override-reason-input"
            placeholder="e.g. vacancy being filled, opening term one period short"
            {...register('overrideReason')}
          />
        </div>
      )}
      <Button type="submit" disabled={pending} data-testid="publish-button">
        {pending ? 'Publishing…' : needsOverride ? 'Publish with override' : 'Publish'}
      </Button>
    </form>
  );
}

function CloneVersionButton({ versionId, sectionId }: { versionId: string; sectionId: string | null }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const onClick = () => {
    startTransition(async () => {
      const result = await cloneTimetableVersion(versionId);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success('Cloned as a new draft.');
      router.push(`/academic-setup/timetable?version=${result.newVersionId}${sectionId ? `&section=${sectionId}` : ''}`);
    });
  };
  return (
    <Button type="button" variant="outline" onClick={onClick} disabled={pending} data-testid="clone-version-button">
      {pending ? 'Cloning…' : 'Clone as new draft'}
    </Button>
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
  roomWarnings,
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
  roomWarnings: RoomWarning[];
  isDraft: boolean;
}) {
  const periods = Array.from(new Set([...Array.from({ length: 8 }, (_, i) => i + 1), ...slots.map((s) => s.period_no)])).sort((a, b) => a - b);
  const slotsAt = (weekday: number, periodNo: number) => slots.filter((s) => s.weekday === weekday && s.period_no === periodNo);
  const roomWarningFor = (roomId: string | null, weekday: number, periodNo: number) =>
    roomId ? roomWarnings.find((w) => w.room_id === roomId && w.weekday === weekday && w.period_no === periodNo) : undefined;
  const selectedVersion = versions.find((v) => v.id === selectedVersionId);

  return (
    <div className="space-y-4">
      <TimetableRealtimeRefresher versionId={selectedVersionId} />
      <VersionSectionPicker versions={versions} selectedVersionId={selectedVersionId} sections={sections} selectedSectionId={selectedSectionId} />

      {selectedVersion && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4">
          <p className="text-sm" data-testid="version-info">
            Version {selectedVersion.version_no} · {selectedVersion.status}
            {selectedVersion.effective_from && ` · effective ${selectedVersion.effective_from}${selectedVersion.effective_to ? ` to ${selectedVersion.effective_to}` : ' onward'}`}
            {selectedVersion.status !== 'DRAFT' && ` · ${selectedVersion.warning_count} warning(s)`}
          </p>
          <CloneVersionButton versionId={selectedVersionId} sectionId={selectedSectionId} />
        </div>
      )}
      {isDraft && <PublishVersionForm versionId={selectedVersionId} />}

      {!selectedSectionId ? (
        <p className="text-sm text-muted-foreground">No sections found for this campus/session.</p>
      ) : !isDraft ? (
        <p data-testid="version-immutable-banner" className="rounded-md border border-amber-400 bg-amber-50 p-3 text-sm text-amber-900">
          This version is no longer a draft — the grid below is read-only.
        </p>
      ) : (
        <WriteSlotForm versionId={selectedVersionId} sectionId={selectedSectionId} subjects={subjects} rooms={rooms} staff={staff} slots={slots} />
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
                    const cellSlots = slotsAt(w.value, periodNo);
                    return (
                      <td key={w.value} data-testid={`grid-cell-${w.value}-${periodNo}`} className="p-2 align-top">
                        {cellSlots.length > 0 ? (
                          <div className="space-y-1">
                            {cellSlots.map((slot) => {
                              const warning = roomWarningFor(slot.room_id, w.value, periodNo);
                              return (
                                <div key={slot.id} className="space-y-0.5" data-testid={`grid-slot-${slot.id}`}>
                                  <p className="font-medium">
                                    {slot.subject?.code ?? '—'}
                                    {slot.elective_bucket !== null && (
                                      <span className="ml-1 text-xs text-blue-600">(bucket {slot.elective_bucket})</span>
                                    )}
                                  </p>
                                  {slot.room && <p className="text-xs text-muted-foreground">{slot.room.code}</p>}
                                  {warning && (
                                    <p className="text-xs font-medium text-amber-700" data-testid={`room-capacity-warning-${w.value}-${periodNo}`}>
                                      ⚠ over capacity ({warning.total_students}/{warning.room_capacity})
                                    </p>
                                  )}
                                </div>
                              );
                            })}
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

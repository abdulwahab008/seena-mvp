'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { CalendarClock, MapPin, Users, GraduationCap, Sparkles, PlusCircle } from 'lucide-react';
import { createTestSitting } from './actions';
import { createTestSittingSchema, type CreateTestSittingInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DateTimePicker } from '@/components/ui/date-picker';

type ClassLevel = { id: string; name_en: string; code?: string };
type RoomVenue = { id: string; code: string; name: string; capacity: number; roomType?: string; blockLabel: string | null };

export function SittingForm({
  campusId,
  sessionId,
  classLevels,
  rooms = [],
}: {
  campusId: string;
  sessionId: string;
  classLevels: ClassLevel[];
  rooms?: RoomVenue[];
}) {
  const [pending, startTransition] = useTransition();
  const {
    handleSubmit,
    control,
    register,
    reset,
    setValue,
    formState: { errors },
  } = useForm<CreateTestSittingInput>({
    resolver: zodResolver(createTestSittingSchema),
    defaultValues: { campusId, sessionId, capacity: 30 },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('classLevelId', values.classLevelId);
    fd.set('startsAt', values.startsAt);
    fd.set('capacity', String(values.capacity));
    if (values.venue) fd.set('venue', values.venue);

    startTransition(async () => {
      const result = await createTestSitting(campusId, sessionId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Test sitting scheduled.');
        reset({ campusId, sessionId, capacity: 30 });
      }
    });
  });

  // Helpers for quick date-time presets (formatted for datetime-local: YYYY-MM-DDTHH:mm)
  const setQuickTime = (daysAhead: number, hour: number, minute: number = 0) => {
    const d = new Date();
    d.setDate(d.getDate() + daysAhead);
    d.setHours(hour, minute, 0, 0);
    const localIso = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    setValue('startsAt', localIso, { shouldValidate: true });
  };

  return (
    <div className="rounded-xl border bg-card p-4 shadow-xs">
      <div className="flex items-center justify-between pb-3 border-b mb-3">
        <div className="flex items-center gap-2">
          <CalendarClock className="h-4 w-4 text-primary" />
          <h2 className="text-sm font-semibold text-foreground">Schedule Sitting</h2>
          <span className="text-xs text-muted-foreground hidden sm:inline">· Set exam date, venue, and capacity</span>
        </div>

        {/* Quick Time Chips */}
        <div className="flex items-center gap-1.5 text-[11px]">
          <span className="text-muted-foreground hidden md:inline">Quick presets:</span>
          <button
            type="button"
            onClick={() => setQuickTime(1, 9, 0)}
            className="rounded px-2 py-0.5 text-xs text-muted-foreground border bg-background hover:bg-muted transition-colors"
          >
            Tomorrow 9 AM
          </button>
          <button
            type="button"
            onClick={() => setQuickTime(1, 14, 0)}
            className="rounded px-2 py-0.5 text-xs text-muted-foreground border bg-background hover:bg-muted transition-colors"
          >
            2 PM
          </button>
          <button
            type="button"
            onClick={() => setQuickTime(3, 10, 0)}
            className="rounded px-2 py-0.5 text-xs text-muted-foreground border bg-background hover:bg-muted transition-colors"
          >
            Saturday 10 AM
          </button>
        </div>
      </div>

      <form onSubmit={onSubmit} className="space-y-3" noValidate>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {/* Class Selector */}
          <div className="space-y-1">
            <Label htmlFor="classLevelId" className="text-xs font-medium text-foreground/80">
              Class <span className="text-destructive">*</span>
            </Label>
            <Controller
              control={control}
              name="classLevelId"
              render={({ field }) => (
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger id="classLevelId" data-testid="sitting-class-trigger" className="h-8.5 text-xs">
                    <SelectValue placeholder="Select class" />
                  </SelectTrigger>
                  <SelectContent>
                    {classLevels.map((c) => (
                      <SelectItem key={c.id} value={c.id} className="text-xs">
                        {c.name_en}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            />
            {errors.classLevelId && <p className="text-[11px] text-destructive">{errors.classLevelId.message}</p>}
          </div>

          {/* Starts At with Interactive Date & Time Picker */}
          <div className="space-y-1">
            <Label htmlFor="startsAt" className="text-xs font-medium text-foreground/80">
              Starts at <span className="text-destructive">*</span>
            </Label>
            <Controller
              control={control}
              name="startsAt"
              render={({ field }) => (
                <DateTimePicker
                  id="startsAt"
                  name="startsAt"
                  value={field.value}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  data-testid="sitting-starts-at"
                  placeholder="Exam date & time"
                  className="h-8.5"
                />
              )}
            />
            {errors.startsAt && <p className="text-[11px] text-destructive">{errors.startsAt.message}</p>}
          </div>

          {/* Venue */}
          <div className="space-y-1">
            <div className="flex items-center justify-between">
              <Label htmlFor="venue" className="text-xs font-medium text-foreground/80">
                Venue
              </Label>
              {rooms.length > 0 && (
                <span className="text-[10px] text-muted-foreground hidden xl:inline">
                  Rooms available
                </span>
              )}
            </div>
            <Input id="venue" placeholder="e.g. Main Hall" className="h-8.5 text-xs" {...register('venue')} />
          </div>

          {/* Capacity */}
          <div className="space-y-1">
            <Label htmlFor="capacity" className="text-xs font-medium text-foreground/80">
              Capacity <span className="text-destructive">*</span>
            </Label>
            <Input id="capacity" type="number" min={1} className="h-8.5 text-xs font-semibold" {...register('capacity')} />
            {errors.capacity && <p className="text-[11px] text-destructive">{errors.capacity.message}</p>}
          </div>
        </div>

        {/* Venue suggestions + submit button in a single line */}
        <div className="flex flex-wrap items-center justify-between gap-2 pt-1">
          <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
            {rooms.length > 0 ? (
              <>
                <span className="text-[11px]">Quick rooms:</span>
                {rooms.slice(0, 3).map((r) => (
                  <button
                    key={r.id}
                    type="button"
                    onClick={() => {
                      setValue('venue', `${r.name} (${r.code})`, { shouldValidate: true });
                      setValue('capacity', r.capacity, { shouldValidate: true });
                    }}
                    className="rounded bg-muted/50 px-1.5 py-0.5 text-[11px] font-medium text-foreground/70 hover:bg-muted hover:text-foreground"
                    title={`${r.name} · Capacity ${r.capacity}`}
                  >
                    {r.code} ({r.capacity})
                  </button>
                ))}
              </>
            ) : (
              <>
                <span className="text-[11px]">Venues:</span>
                {['Main Hall', 'Exam Room 1'].map((v) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => setValue('venue', v, { shouldValidate: true })}
                    className="rounded bg-muted/50 px-1.5 py-0.5 text-[11px] font-medium text-foreground/70 hover:bg-muted hover:text-foreground"
                  >
                    {v}
                  </button>
                ))}
              </>
            )}
          </div>

          <Button type="submit" size="sm" disabled={pending} className="h-8 gap-1.5 text-xs">
            <PlusCircle className="h-3.5 w-3.5" />
            {pending ? 'Scheduling…' : 'Schedule sitting'}
          </Button>
        </div>
      </form>
    </div>
  );
}


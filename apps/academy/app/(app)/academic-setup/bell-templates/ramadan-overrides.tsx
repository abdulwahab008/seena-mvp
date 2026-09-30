'use client';

import { useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createDateRangeBellRule, updateBellRuleDates, deleteBellCalendarRule } from './actions';
import {
  createDateRangeBellRuleSchema,
  updateBellRuleDatesSchema,
  WEEKDAY_LABELS,
  BELL_SHIFTS,
  type CreateDateRangeBellRuleInput,
  type UpdateBellRuleDatesInput,
} from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';

export type DateRangeRuleRow = {
  id: string;
  shift: string;
  weekday: number | null;
  date_from: string;
  date_to: string | null;
  precedence: number;
  note: string | null;
  bell_template: { code: string; name: string } | null;
};

const DEFAULT_VALUES: Partial<CreateDateRangeBellRuleInput> = { shift: 'MORNING', precedence: 100 };

// AC2: the Ruet-e-Hilal sighting is announced around 21:00 the night
// before, so an already-active window routinely has to move by a day.
function CorrectDatesForm({ rule }: { rule: DateRangeRuleRow }) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<UpdateBellRuleDatesInput>({
    resolver: zodResolver(updateBellRuleDatesSchema),
    defaultValues: { dateFrom: rule.date_from, dateTo: rule.date_to ?? '' },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('dateFrom', values.dateFrom);
    if (values.dateTo) fd.set('dateTo', values.dateTo);
    startTransition(async () => {
      const result = await updateBellRuleDates(rule.id, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Dates corrected.');
        setOpen(false);
      }
    });
  });

  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)} data-testid={`correct-dates-${rule.id}`}>
        Correct dates
      </Button>
    );
  }

  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" data-testid={`correct-dates-form-${rule.id}`} noValidate>
      <div className="space-y-1">
        <Label htmlFor={`from-${rule.id}`}>New start</Label>
        <Controller
          control={control}
          name="dateFrom"
          render={({ field }) => (
            <DatePicker
              id={`from-${rule.id}`}
              name="dateFrom"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="Start date"
              data-testid={`correct-date-from-${rule.id}`}
            />
          )}
        />
        {errors.dateFrom && <p className="text-xs text-destructive">{errors.dateFrom.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor={`to-${rule.id}`}>New end</Label>
        <Controller
          control={control}
          name="dateTo"
          render={({ field }) => (
            <DatePicker
              id={`to-${rule.id}`}
              name="dateTo"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="End date"
              data-testid={`correct-date-to-${rule.id}`}
            />
          )}
        />
        {errors.dateTo && <p className="text-xs text-destructive">{errors.dateTo.message}</p>}
      </div>
      <Button type="submit" size="sm" disabled={pending} data-testid={`save-dates-${rule.id}`}>
        {pending ? 'Saving…' : 'Save'}
      </Button>
      <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
        Cancel
      </Button>
    </form>
  );
}

function RemoveOverrideButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  const onClick = () => {
    startTransition(async () => {
      const result = await deleteBellCalendarRule(id, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Override removed.');
    });
  };
  return (
    <Button type="button" size="sm" variant="ghost" disabled={pending} onClick={onClick} data-testid={`delete-override-${id}`}>
      Remove
    </Button>
  );
}

export function RamadanOverrides({
  campusId,
  templates,
  rules,
}: {
  campusId: string;
  templates: { id: string; shift: string; code: string; name: string }[];
  rules: DateRangeRuleRow[];
}) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    reset,
    watch,
    formState: { errors },
  } = useForm<CreateDateRangeBellRuleInput>({
    resolver: zodResolver(createDateRangeBellRuleSchema),
    defaultValues: DEFAULT_VALUES,
  });
  const selectedShift = watch('shift');
  const shiftTemplates = templates.filter((t) => t.shift === selectedShift);

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('shift', values.shift);
    fd.set('bellTemplateId', values.bellTemplateId);
    if (values.weekday !== undefined) fd.set('weekday', String(values.weekday));
    fd.set('dateFrom', values.dateFrom);
    if (values.dateTo) fd.set('dateTo', values.dateTo);
    fd.set('precedence', String(values.precedence));
    if (values.note) fd.set('note', values.note);

    startTransition(async () => {
      const result = await createDateRangeBellRule(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Override activated.');
        reset(DEFAULT_VALUES);
      }
    });
  });

  return (
    <div className="space-y-3">
      <h2 className="text-lg font-medium">Ramadan &amp; Date-range Overrides</h2>
      <p className="text-sm text-muted-foreground">
        FR-F03 — switch the campus onto a different bell template for a date range. It outranks the weekday rules above, and
        reverts on its own the day after the range ends. Leave the weekday blank for every day in the range; set one for a
        shorter-still Ramadan Jumma (give it a higher precedence than the general Ramadan rule).
      </p>
      <form
        onSubmit={onSubmit}
        className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4"
        data-testid="create-date-rule-form"
        noValidate
      >
        <div className="space-y-1">
          <Label htmlFor="override-shift">Override shift</Label>
          <Controller
            control={control}
            name="shift"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="override-shift-trigger">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {BELL_SHIFTS.map((s) => (
                    <SelectItem key={s} value={s}>
                      {s}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="override-template">Override template</Label>
          <Controller
            control={control}
            name="bellTemplateId"
            render={({ field }) => (
              <Select value={field.value ?? ''} onValueChange={field.onChange}>
                <SelectTrigger data-testid="override-template-trigger">
                  <SelectValue placeholder="Choose template" />
                </SelectTrigger>
                <SelectContent>
                  {shiftTemplates.map((t) => (
                    <SelectItem key={t.id} value={t.id}>
                      {t.name} ({t.code})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.bellTemplateId && <p className="text-xs text-destructive">{errors.bellTemplateId.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="override-date-from">Override from</Label>
          <Controller
            control={control}
            name="dateFrom"
            render={({ field }) => (
              <DatePicker
                id="override-date-from"
                name="dateFrom"
                value={field.value}
                onChange={field.onChange}
                onBlur={field.onBlur}
                placeholder="From date"
                data-testid="override-date-from"
              />
            )}
          />
          {errors.dateFrom && <p className="text-xs text-destructive">{errors.dateFrom.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="override-date-to">Override to</Label>
          <Controller
            control={control}
            name="dateTo"
            render={({ field }) => (
              <DatePicker
                id="override-date-to"
                name="dateTo"
                value={field.value}
                onChange={field.onChange}
                onBlur={field.onBlur}
                placeholder="To date"
                data-testid="override-date-to"
              />
            )}
          />
          {errors.dateTo && <p className="text-xs text-destructive">{errors.dateTo.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="override-weekday">Weekday (optional)</Label>
          <Controller
            control={control}
            name="weekday"
            render={({ field }) => (
              <Select
                value={field.value !== undefined ? String(field.value) : 'ANY'}
                onValueChange={(v) => field.onChange(v === 'ANY' ? undefined : Number(v))}
              >
                <SelectTrigger data-testid="override-weekday-trigger">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="ANY">Every day in range</SelectItem>
                  {WEEKDAY_LABELS.map((label, i) => (
                    <SelectItem key={label} value={String(i)}>
                      {label} only
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="override-precedence">Override precedence</Label>
          <Input id="override-precedence" type="number" data-testid="override-precedence-input" {...register('precedence')} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="override-note">Ramadan note</Label>
          <Input id="override-note" placeholder="Ramadan 1448" {...register('note')} />
        </div>
        <Button type="submit" disabled={pending} data-testid="create-date-rule-button" className="col-span-full w-fit">
          {pending ? 'Saving…' : 'Activate override'}
        </Button>
      </form>

      {rules.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="no-date-rules">
          No date-range overrides active.
        </p>
      ) : (
        <div className="space-y-2">
          {rules.map((r) => (
            <Card key={r.id} data-testid={`date-rule-row-${r.id}`}>
              <CardContent className="flex flex-wrap items-center justify-between gap-3 p-4">
                <div>
                  <p className="font-medium">
                    {r.date_from} → {r.date_to ?? r.date_from}{' '}
                    <span className="text-muted-foreground">
                      ({r.shift}
                      {r.weekday !== null ? `, ${WEEKDAY_LABELS[r.weekday]} only` : ''})
                    </span>
                  </p>
                  <p className="text-sm text-muted-foreground">
                    {r.bell_template?.name} ({r.bell_template?.code}) · precedence {r.precedence}
                    {r.note ? ` · ${r.note}` : ''}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <CorrectDatesForm rule={r} />
                  <RemoveOverrideButton id={r.id} />
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

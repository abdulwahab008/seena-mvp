'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createBellCalendarRule, deleteBellCalendarRule } from './actions';
import { createBellCalendarRuleSchema, WEEKDAY_LABELS, BELL_SHIFTS, type CreateBellCalendarRuleInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type CalendarRuleRow = {
  id: string;
  shift: string;
  weekday: number | null;
  precedence: number;
  note: string | null;
  bell_template: { code: string; name: string } | null;
};

const DEFAULT_VALUES: Partial<CreateBellCalendarRuleInput> = { shift: 'MORNING', precedence: 50 };

function DeleteRuleButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  const onClick = () => {
    startTransition(async () => {
      const result = await deleteBellCalendarRule(id, { error: null }, new FormData());
      if (result.error) toast.error(result.error);
      else toast.success('Rule removed.');
    });
  };
  return (
    <Button type="button" size="sm" variant="ghost" disabled={pending} onClick={onClick} data-testid={`delete-rule-${id}`}>
      Remove
    </Button>
  );
}

export function BellCalendarRules({
  campusId,
  templates,
  rules,
}: {
  campusId: string;
  templates: { id: string; shift: string; code: string; name: string }[];
  rules: CalendarRuleRow[];
}) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    control,
    handleSubmit,
    reset,
    watch,
    formState: { errors },
  } = useForm<CreateBellCalendarRuleInput>({ resolver: zodResolver(createBellCalendarRuleSchema), defaultValues: DEFAULT_VALUES });
  const selectedShift = watch('shift');
  const shiftTemplates = templates.filter((t) => t.shift === selectedShift);

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('shift', values.shift);
    fd.set('bellTemplateId', values.bellTemplateId);
    fd.set('weekday', String(values.weekday));
    fd.set('precedence', String(values.precedence));
    if (values.note) fd.set('note', values.note);

    startTransition(async () => {
      const result = await createBellCalendarRule(campusId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Rule created.');
        reset(DEFAULT_VALUES);
      }
    });
  });

  return (
    <div className="space-y-3">
      <h2 className="text-lg font-medium">Calendar Rules</h2>
      <p className="text-sm text-muted-foreground">
        FR-F02 — override which bell template applies on a given weekday (e.g. a shortened Friday for Jumma).
      </p>
      <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" data-testid="create-bell-rule-form" noValidate>
        <div className="space-y-1">
          <Label htmlFor="rule-shift">Shift</Label>
          <Controller
            control={control}
            name="shift"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="rule-shift-trigger">
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
          <Label htmlFor="rule-weekday">Weekday</Label>
          <Controller
            control={control}
            name="weekday"
            render={({ field }) => (
              <Select
                // Always controlled (never `undefined`) — an
                // undefined/string flip on reset() desyncs Radix's
                // visual state from RHF's, leaving the trigger showing
                // a stale label after reset even though the underlying
                // form value is genuinely cleared.
                value={field.value !== undefined ? String(field.value) : ''}
                onValueChange={(v) => field.onChange(Number(v))}
              >
                <SelectTrigger data-testid="rule-weekday-trigger">
                  <SelectValue placeholder="Choose weekday" />
                </SelectTrigger>
                <SelectContent>
                  {WEEKDAY_LABELS.map((label, i) => (
                    <SelectItem key={label} value={String(i)}>
                      {label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="rule-template">Template</Label>
          <Controller
            control={control}
            name="bellTemplateId"
            render={({ field }) => (
              <Select value={field.value ?? ''} onValueChange={field.onChange}>
                <SelectTrigger data-testid="rule-template-trigger">
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
          <Label htmlFor="rule-precedence">Precedence</Label>
          <Input id="rule-precedence" type="number" data-testid="rule-precedence-input" {...register('precedence')} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="rule-note">Note (optional)</Label>
          <Input id="rule-note" placeholder="Jumma break" {...register('note')} />
        </div>
        <Button type="submit" disabled={pending} data-testid="create-bell-rule-button" className="col-span-full w-fit">
          {pending ? 'Saving…' : 'Add rule'}
        </Button>
      </form>

      {rules.length === 0 ? (
        <p className="text-sm text-muted-foreground">No calendar rules yet — every weekday resolves to the default template.</p>
      ) : (
        <div className="space-y-2">
          {rules.map((r) => (
            <Card key={r.id} data-testid={`bell-rule-row-${r.id}`}>
              <CardContent className="flex items-center justify-between p-4">
                <div>
                  <p className="font-medium">
                    {r.weekday !== null ? WEEKDAY_LABELS[r.weekday] : 'Date range'} <span className="text-muted-foreground">({r.shift})</span>
                  </p>
                  <p className="text-sm text-muted-foreground">
                    {r.bell_template?.name} ({r.bell_template?.code}) · precedence {r.precedence}
                    {r.note ? ` · ${r.note}` : ''}
                  </p>
                </div>
                <DeleteRuleButton id={r.id} />
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

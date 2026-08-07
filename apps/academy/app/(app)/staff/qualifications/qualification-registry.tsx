'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { addStaffQualification, verifyStaffQualification } from './actions';
import { addStaffQualificationSchema, QUALIFICATION_LEVELS, type AddStaffQualificationInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type StaffOption = { user_id: string; full_name: string };
type QualificationRow = {
  id: string;
  staff_id: string;
  level: (typeof QUALIFICATION_LEVELS)[number];
  discipline: string;
  institution: string;
  year_completed: number;
  verification_status: 'pending' | 'verified' | 'rejected';
};

export function QualificationRegistry({ staff, qualifications }: { staff: StaffOption[]; qualifications: QualificationRow[] }) {
  const [pending, startTransition] = useTransition();
  const staffName = (id: string) => staff.find((s) => s.user_id === id)?.full_name ?? id;

  const {
    handleSubmit,
    control,
    register,
    reset,
    formState: { errors },
  } = useForm<AddStaffQualificationInput>({ resolver: zodResolver(addStaffQualificationSchema) });

  const onAdd = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('staffId', values.staffId);
    fd.set('level', values.level);
    fd.set('discipline', values.discipline);
    fd.set('institution', values.institution);
    fd.set('yearCompleted', String(values.yearCompleted));

    startTransition(async () => {
      const result = await addStaffQualification({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Qualification saved.');
        reset({ staffId: values.staffId, discipline: '', institution: '' });
      }
    });
  });

  const onDecide = (qualificationId: string, status: 'verified' | 'rejected') => {
    const fd = new FormData();
    fd.set('qualificationId', qualificationId);
    fd.set('status', status);
    startTransition(async () => {
      const result = await verifyStaffQualification({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success(status === 'verified' ? 'Qualification verified.' : 'Qualification rejected.');
    });
  };

  return (
    <div className="space-y-6">
      <form onSubmit={onAdd} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" noValidate>
        <div className="space-y-1">
          <Label htmlFor="staffId">Staff member</Label>
          <Controller
            control={control}
            name="staffId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="qualification-staff-trigger">
                  <SelectValue placeholder="Select staff" />
                </SelectTrigger>
                <SelectContent>
                  {staff.map((s) => (
                    <SelectItem key={s.user_id} value={s.user_id}>
                      {s.full_name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.staffId && <p className="text-xs text-destructive">{errors.staffId.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="level">Level</Label>
          <Controller
            control={control}
            name="level"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="qualification-level-trigger">
                  <SelectValue placeholder="Select level" />
                </SelectTrigger>
                <SelectContent>
                  {QUALIFICATION_LEVELS.map((l) => (
                    <SelectItem key={l} value={l}>
                      {l}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.level && <p className="text-xs text-destructive">{errors.level.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="discipline">Discipline</Label>
          <Input id="discipline" data-testid="qualification-discipline-input" {...register('discipline')} />
          {errors.discipline && <p className="text-xs text-destructive">{errors.discipline.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="institution">Institution</Label>
          <Input id="institution" data-testid="qualification-institution-input" {...register('institution')} />
          {errors.institution && <p className="text-xs text-destructive">{errors.institution.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="yearCompleted">Year completed</Label>
          <Input id="yearCompleted" type="number" data-testid="qualification-year-input" {...register('yearCompleted')} />
          {errors.yearCompleted && <p className="text-xs text-destructive">{errors.yearCompleted.message}</p>}
        </div>
        <Button type="submit" disabled={pending} className="col-span-full w-fit">
          {pending ? 'Saving…' : 'Add qualification'}
        </Button>
      </form>

      <div className="rounded-lg border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="p-2">Staff</th>
              <th className="p-2">Level</th>
              <th className="p-2">Discipline</th>
              <th className="p-2">Institution</th>
              <th className="p-2">Year</th>
              <th className="p-2">Status</th>
              <th className="p-2" />
            </tr>
          </thead>
          <tbody>
            {qualifications.map((q) => (
              <tr key={q.id} data-testid={`qualification-row-${q.id}`} className="border-b last:border-0">
                <td className="p-2">{staffName(q.staff_id)}</td>
                <td className="p-2 capitalize">{q.level}</td>
                <td className="p-2">{q.discipline}</td>
                <td className="p-2">{q.institution}</td>
                <td className="p-2">{q.year_completed}</td>
                <td className="p-2" data-testid={`qualification-status-${q.id}`}>
                  {q.verification_status}
                </td>
                <td className="p-2">
                  {q.verification_status === 'pending' && (
                    <div className="flex gap-1">
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={pending}
                        onClick={() => onDecide(q.id, 'verified')}
                        data-testid={`qualification-verify-${q.id}`}
                      >
                        Verify
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={pending}
                        onClick={() => onDecide(q.id, 'rejected')}
                        data-testid={`qualification-reject-${q.id}`}
                      >
                        Reject
                      </Button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
            {qualifications.length === 0 && (
              <tr>
                <td className="p-2 text-muted-foreground" colSpan={7}>
                  No qualifications recorded yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

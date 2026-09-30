'use client';

import { useState, useEffect, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { applyLeave, getStaffLeaveBalances } from './actions';
import { applyLeaveSchema, type ApplyLeaveInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';
import { Badge } from '@/components/ui/badge';
import { Users, AlertCircle } from 'lucide-react';

export type LeaveType = {
  id: string;
  code: string;
  name_en: string;
  is_paid?: boolean;
  entitlement_days?: number;
  doc_required_after_days?: number | null;
};

export type StaffOption = {
  id: string;
  full_name: string;
  employee_code: string;
};

export function ApplyLeaveForm({
  staffId,
  leaveTypes,
  balances,
  staffList = [],
  isApprover = false,
}: {
  staffId?: string | null;
  leaveTypes: LeaveType[];
  balances: Record<string, number>;
  staffList?: StaffOption[];
  isApprover?: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [fetchingStaff, startStaffTransition] = useTransition();

  // Selected staff ID: default to current staffId or first staff member in staffList
  const [selectedStaffId, setSelectedStaffId] = useState<string>(
    staffId || (staffList.length > 0 && staffList[0] ? staffList[0].id : '')
  );
  const [activeLeaveTypes, setActiveLeaveTypes] = useState<LeaveType[]>(leaveTypes);
  const [activeBalances, setActiveBalances] = useState<Record<string, number>>(balances);

  // Sync with incoming props when viewing the current staff member
  useEffect(() => {
    if (!selectedStaffId || selectedStaffId === staffId) {
      setActiveLeaveTypes(leaveTypes);
      setActiveBalances(balances);
    }
  }, [leaveTypes, balances, selectedStaffId, staffId]);

  const {
    register,
    handleSubmit,
    control,
    reset,
    watch,
    setValue,
    formState: { errors },
  } = useForm<ApplyLeaveInput>({
    resolver: zodResolver(applyLeaveSchema),
    defaultValues: {
      leaveTypeId: leaveTypes[0]?.id ?? '',
      fromDate: '',
      toDate: '',
      isHalfDay: false,
      reason: '',
    },
  });

  const isHalfDay = watch('isHalfDay');
  const currentLeaveTypeId = watch('leaveTypeId');

  // When activeLeaveTypes updates and current selection is invalid, set to first available
  useEffect(() => {
    if (activeLeaveTypes.length > 0 && activeLeaveTypes[0]) {
      const exists = activeLeaveTypes.some((t) => t.id === currentLeaveTypeId);
      if (!exists) {
        setValue('leaveTypeId', activeLeaveTypes[0].id);
      }
    }
  }, [activeLeaveTypes, currentLeaveTypeId, setValue]);

  const handleStaffChange = (newStaffId: string) => {
    setSelectedStaffId(newStaffId);
    if (newStaffId === staffId) {
      setActiveLeaveTypes(leaveTypes);
      setActiveBalances(balances);
      return;
    }
    startStaffTransition(async () => {
      const res = await getStaffLeaveBalances(newStaffId);
      if (res.error) {
        toast.error(res.error);
      } else {
        if (res.leaveTypes) setActiveLeaveTypes(res.leaveTypes);
        if (res.balances) setActiveBalances(res.balances);
      }
    });
  };

  const onSubmit = handleSubmit((values) => {
    const targetStaffId = selectedStaffId || staffId;
    if (!targetStaffId) {
      toast.error('Please select a staff member to apply for leave.');
      return;
    }

    const fd = new FormData();
    fd.set('leaveTypeId', values.leaveTypeId);
    fd.set('fromDate', values.fromDate);
    fd.set('toDate', values.isHalfDay ? values.fromDate : values.toDate);
    if (values.isHalfDay) fd.set('isHalfDay', 'on');
    if (values.reason) fd.set('reason', values.reason);

    startTransition(async () => {
      const result = await applyLeave(targetStaffId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Leave application submitted.');
        reset({ leaveTypeId: values.leaveTypeId, fromDate: '', toDate: '', isHalfDay: false, reason: '' });
      }
    });
  });

  const selectedLeaveType = activeLeaveTypes.find((t) => t.id === currentLeaveTypeId);

  return (
    <div className="space-y-4 rounded-xl border bg-card p-5 shadow-xs">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 pb-3 border-b">
        <div>
          <h2 className="text-base font-semibold text-foreground">Apply for Leave</h2>
          <p className="text-xs text-muted-foreground">
            Submit short-notice casual, sick, or special leave. Total annual paid limit is strictly 18 days.
          </p>
        </div>
        {selectedLeaveType && (
          <Badge variant={selectedLeaveType.is_paid ? 'success' : 'outline'} className="w-fit text-xs">
            {selectedLeaveType.is_paid ? 'Paid Leave Category' : 'Unpaid (Loss of Pay)'}
          </Badge>
        )}
      </div>

      {isApprover && staffList.length > 0 && (
        <div className="space-y-1.5 p-3 rounded-lg bg-muted/40 border">
          <div className="flex items-center justify-between">
            <Label htmlFor="staff-select" className="text-xs font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
              <Users className="h-3.5 w-3.5 text-primary" />
              Staff Member (Administrative Application)
            </Label>
            {selectedStaffId === staffId && (
              <Badge variant="primary" className="text-[10px] py-0">Self</Badge>
            )}
          </div>
          <Select value={selectedStaffId} onValueChange={handleStaffChange}>
            <SelectTrigger id="staff-select" className="bg-background">
              <SelectValue placeholder="Choose staff member" />
            </SelectTrigger>
            <SelectContent>
              {staffList.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.full_name} ({s.employee_code}) {s.id === staffId ? '— (You)' : ''}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      )}

      {/* Balance chips */}
      <div className="space-y-1.5">
        <div className="text-xs font-medium text-muted-foreground">
          {fetchingStaff ? 'Updating balances…' : 'Available Entitlement Balances:'}
        </div>
        <div className="flex flex-wrap gap-2">
          {activeLeaveTypes.length === 0 ? (
            <p className="text-xs text-muted-foreground italic">No leave policies found or granted.</p>
          ) : (
            activeLeaveTypes.map((t) => (
              <span
                key={t.id}
                data-testid={`leave-balance-${t.code}`}
                className="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs text-muted-foreground bg-muted/20"
              >
                <span className="font-medium text-foreground">{t.name_en}</span>: {(activeBalances[t.id] ?? 0).toFixed(2)}d left
                {t.is_paid ? (
                  <span className="text-[10px] font-semibold uppercase px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-300">
                    Paid
                  </span>
                ) : (
                  <span className="text-[10px] font-semibold uppercase px-1.5 py-0.5 rounded bg-amber-100 text-amber-800 dark:bg-amber-950/60 dark:text-amber-300">
                    Unpaid
                  </span>
                )}
              </span>
            ))
          )}
        </div>
      </div>

      <form onSubmit={onSubmit} className="grid grid-cols-2 gap-4 md:grid-cols-4" noValidate>
        <div className="space-y-1.5">
          <Label htmlFor="leaveTypeId">Leave type</Label>
          <Controller
            control={control}
            name="leaveTypeId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="leave-type-trigger">
                  <SelectValue placeholder="Select a leave type" />
                </SelectTrigger>
                <SelectContent>
                  {activeLeaveTypes.map((t) => (
                    <SelectItem key={t.id} value={t.id}>
                      {t.name_en}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.leaveTypeId && <p className="text-xs text-destructive">{errors.leaveTypeId.message}</p>}
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="fromDate">From</Label>
          <Controller
            control={control}
            name="fromDate"
            render={({ field }) => (
              <DatePicker
                id="fromDate"
                name="fromDate"
                value={field.value}
                onChange={field.onChange}
                onBlur={field.onBlur}
                placeholder="From date"
                data-testid="leave-from-date"
              />
            )}
          />
          {errors.fromDate && <p className="text-xs text-destructive">{errors.fromDate.message}</p>}
        </div>

        {!isHalfDay && (
          <div className="space-y-1.5">
            <Label htmlFor="toDate">To</Label>
            <Controller
              control={control}
              name="toDate"
              render={({ field }) => (
                <DatePicker
                  id="toDate"
                  name="toDate"
                  value={field.value}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  placeholder="To date"
                  data-testid="leave-to-date"
                />
              )}
            />
            {errors.toDate && <p className="text-xs text-destructive">{errors.toDate.message}</p>}
          </div>
        )}

        <div className="flex items-center gap-2 self-end pb-2 text-sm">
          <label className="flex items-center gap-2 cursor-pointer select-none">
            <input
              type="checkbox"
              {...register('isHalfDay')}
              className="h-4 w-4 rounded border-input text-primary focus:ring-primary"
            />
            <span className="font-medium text-foreground">Half day</span>
          </label>
        </div>

        <div className="col-span-2 space-y-1.5 md:col-span-4">
          <Label htmlFor="reason">Reason (optional)</Label>
          <Input
            id="reason"
            placeholder="e.g. Urgent family matter / medical checkup"
            {...register('reason')}
          />
        </div>

        {selectedLeaveType?.code === 'SICK' && (
          <div className="col-span-2 md:col-span-4 flex items-center gap-2 p-2.5 rounded-lg border border-amber-200 bg-amber-50/50 dark:border-amber-900/50 dark:bg-amber-950/20 text-xs text-amber-800 dark:text-amber-300">
            <AlertCircle className="h-4 w-4 shrink-0" />
            <span>
              <strong>Medical Leave Policy:</strong> If taking more than 2 consecutive days of sick leave, an official medical certificate must be presented to the administration upon return.
            </span>
          </div>
        )}

        <div className="col-span-2 md:col-span-4 pt-1">
          <Button type="submit" disabled={pending || fetchingStaff} className="w-fit">
            {pending ? 'Submitting…' : 'Apply for leave'}
          </Button>
        </div>
      </form>
    </div>
  );
}

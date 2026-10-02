'use client';

import * as React from 'react';
import { Calendar as CalendarIcon, ChevronLeft, ChevronRight, X, Clock, Check } from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';

export interface DatePickerProps {
  id?: string;
  name?: string;
  value?: string; // YYYY-MM-DD
  defaultValue?: string; // YYYY-MM-DD
  onChange?: (date: string) => void;
  onBlur?: () => void;
  placeholder?: string;
  min?: string;
  max?: string;
  disabled?: boolean;
  className?: string;
  required?: boolean;
  'data-testid'?: string;
  yearRange?: { start?: number; end?: number };
}

const MONTHS = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const DAYS = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

function parseISODate(isoString?: string): Date | null {
  if (!isoString) return null;
  const parts = isoString.split('-');
  if (parts.length !== 3) return null;
  const y = parseInt(parts[0] ?? '', 10);
  const m = parseInt(parts[1] ?? '', 10) - 1;
  const d = parseInt(parts[2] ?? '', 10);
  if (isNaN(y) || isNaN(m) || isNaN(d)) return null;
  return new Date(y, m, d);
}

function formatDisplayDate(isoString?: string): string {
  const parsed = parseISODate(isoString);
  if (!parsed) return '';
  const day = String(parsed.getDate()).padStart(2, '0');
  const month = MONTHS[parsed.getMonth()]?.slice(0, 3) ?? '';
  const year = parsed.getFullYear();
  return `${day} ${month} ${year}`;
}

export function DatePicker({
  id,
  name,
  value: controlledValue,
  defaultValue,
  onChange,
  onBlur,
  placeholder = 'Select date (YYYY-MM-DD)',
  min,
  max,
  disabled = false,
  className,
  required,
  'data-testid': testId,
  yearRange,
}: DatePickerProps) {
  const [internalValue, setInternalValue] = React.useState<string>(controlledValue ?? defaultValue ?? '');
  const [open, setOpen] = React.useState(false);
  const containerRef = React.useRef<HTMLDivElement>(null);

  const selectedDate = parseISODate(controlledValue !== undefined ? controlledValue : internalValue);

  // Calendar navigation state (year & month)
  const [viewYear, setViewYear] = React.useState<number>(() => selectedDate?.getFullYear() ?? new Date().getFullYear());
  const [viewMonth, setViewMonth] = React.useState<number>(() => selectedDate?.getMonth() ?? new Date().getMonth());

  // Keep view in sync when value changes externally
  React.useEffect(() => {
    if (controlledValue !== undefined) {
      setInternalValue(controlledValue);
      if (controlledValue) {
        const d = parseISODate(controlledValue);
        if (d) {
          setViewYear(d.getFullYear());
          setViewMonth(d.getMonth());
        }
      }
    }
  }, [controlledValue]);

  // Close popup on outside click
  React.useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    }
    if (open) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [open]);

  const handleSelectDay = (day: number) => {
    const y = viewYear;
    const m = String(viewMonth + 1).padStart(2, '0');
    const d = String(day).padStart(2, '0');
    const iso = `${y}-${m}-${d}`;
    if (controlledValue === undefined) {
      setInternalValue(iso);
    }
    onChange?.(iso);
    setOpen(false);
  };

  const handleClear = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (controlledValue === undefined) {
      setInternalValue('');
    }
    onChange?.('');
  };

  const handleToday = () => {
    const now = new Date();
    const y = now.getFullYear();
    const m = String(now.getMonth() + 1).padStart(2, '0');
    const d = String(now.getDate()).padStart(2, '0');
    const iso = `${y}-${m}-${d}`;
    setViewYear(y);
    setViewMonth(now.getMonth());
    if (controlledValue === undefined) {
      setInternalValue(iso);
    }
    onChange?.(iso);
    setOpen(false);
  };

  // Calendar calculations
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const firstDayOfWeek = new Date(viewYear, viewMonth, 1).getDay();

  // Year range options (from 85 years ago to +15 years in future)
  const currentYear = new Date().getFullYear();
  const startYear = yearRange?.start ?? currentYear - 85;
  const endYear = yearRange?.end ?? currentYear + 15;
  const yearOptions: number[] = [];
  for (let y = endYear; y >= startYear; y--) {
    yearOptions.push(y);
  }

  const currentValue = controlledValue !== undefined ? controlledValue : internalValue;

  return (
    <div ref={containerRef} className={cn('relative inline-block w-full', className)}>
      <div className="relative flex items-center w-full">
        {/* Real input for automation, direct typing, and form submissions */}
        <input
          id={id}
          name={name}
          type="text"
          value={currentValue}
          onChange={(e) => {
            const val = e.target.value;
            if (controlledValue === undefined) {
              setInternalValue(val);
            }
            onChange?.(val);
            const parsed = parseISODate(val);
            if (parsed) {
              setViewYear(parsed.getFullYear());
              setViewMonth(parsed.getMonth());
            }
          }}
          onClick={() => !disabled && setOpen(true)}
          onBlur={onBlur}
          placeholder={placeholder}
          disabled={disabled}
          required={required}
          data-testid={testId}
          className={cn(
            'flex h-10 w-full rounded-md border border-input bg-background pl-3 pr-16 py-2 text-sm ring-offset-background transition-colors',
            'file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2',
            disabled && 'cursor-not-allowed opacity-50',
            currentValue ? 'font-mono' : ''
          )}
        />

        {/* Clear & Calendar action buttons */}
        <div className="absolute right-2 flex items-center gap-1 text-muted-foreground">
          {currentValue && !disabled && (
            <button
              type="button"
              onClick={handleClear}
              className="rounded p-1 hover:bg-muted hover:text-foreground cursor-pointer transition-colors"
              aria-label="Clear date"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          )}

          <button
            type="button"
            onClick={() => !disabled && setOpen(!open)}
            disabled={disabled}
            aria-label="Toggle calendar date picker"
            className="rounded p-1 hover:bg-muted hover:text-foreground cursor-pointer transition-colors"
          >
            <CalendarIcon className="h-4 w-4" />
          </button>
        </div>
      </div>

      {/* Popover Calendar */}
      {open && (
        <div
          className="absolute left-0 z-50 mt-1 w-72 rounded-lg border bg-popover p-3 text-popover-foreground shadow-2xl animate-in fade-in-0 zoom-in-95"
          data-testid={`${testId ?? 'date-picker'}-popover`}
        >
          {/* Header Controls: Month & Year Jump */}
          <div className="flex items-center justify-between gap-1 pb-2 border-b">
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-7 w-7 p-0 cursor-pointer"
              onClick={() => {
                if (viewMonth === 0) {
                  setViewMonth(11);
                  setViewYear((y) => y - 1);
                } else {
                  setViewMonth((m) => m - 1);
                }
              }}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>

            <div className="flex items-center gap-1">
              <select
                className="h-7 rounded border border-input bg-background px-1.5 text-xs font-medium focus:outline-none focus:ring-1 focus:ring-ring cursor-pointer"
                value={viewMonth}
                onChange={(e) => setViewMonth(parseInt(e.target.value, 10))}
              >
                {MONTHS.map((m, idx) => (
                  <option key={m} value={String(idx)}>
                    {m}
                  </option>
                ))}
              </select>

              <select
                className="h-7 rounded border border-input bg-background px-1.5 text-xs font-medium focus:outline-none focus:ring-1 focus:ring-ring cursor-pointer"
                value={viewYear}
                onChange={(e) => setViewYear(parseInt(e.target.value, 10))}
              >
                {yearOptions.map((yr) => (
                  <option key={yr} value={String(yr)}>
                    {yr}
                  </option>
                ))}
              </select>
            </div>

            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-7 w-7 p-0 cursor-pointer"
              onClick={() => {
                if (viewMonth === 11) {
                  setViewMonth(0);
                  setViewYear((y) => y + 1);
                } else {
                  setViewMonth((m) => m + 1);
                }
              }}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>

          {/* Days Header */}
          <div className="grid grid-cols-7 gap-1 pt-2 text-center text-xs font-semibold text-muted-foreground">
            {DAYS.map((d) => (
              <div key={d} className="h-6 flex items-center justify-center">
                {d}
              </div>
            ))}
          </div>

          {/* Days Grid */}
          <div className="grid grid-cols-7 gap-1 pt-1">
            {Array.from({ length: firstDayOfWeek }).map((_, i) => (
              <div key={`empty-${i}`} className="h-8" />
            ))}

            {Array.from({ length: daysInMonth }).map((_, i) => {
              const day = i + 1;
              const isSelected =
                selectedDate &&
                selectedDate.getFullYear() === viewYear &&
                selectedDate.getMonth() === viewMonth &&
                selectedDate.getDate() === day;

              const isToday =
                new Date().getFullYear() === viewYear &&
                new Date().getMonth() === viewMonth &&
                new Date().getDate() === day;

              return (
                <button
                  key={`day-${day}`}
                  type="button"
                  onClick={() => handleSelectDay(day)}
                  className={cn(
                    'h-8 w-8 rounded-md text-xs font-medium transition-colors flex items-center justify-center mx-auto cursor-pointer',
                    isSelected
                      ? 'bg-indigo-600 text-white font-bold hover:bg-indigo-700'
                      : 'hover:bg-accent hover:text-accent-foreground',
                    isToday && !isSelected && 'border border-indigo-600 text-indigo-600 font-semibold'
                  )}
                >
                  {day}
                </button>
              );
            })}
          </div>

          {/* Footer Shortcuts */}
          <div className="mt-2 flex items-center justify-between border-t pt-2 text-xs">
            <button
              type="button"
              onClick={handleToday}
              className="text-indigo-600 dark:text-indigo-400 hover:underline font-medium cursor-pointer"
            >
              Today
            </button>
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="text-muted-foreground hover:text-foreground cursor-pointer"
            >
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

export interface DateTimePickerProps {
  id?: string;
  name?: string;
  value?: string; // YYYY-MM-DDTHH:mm or ISO format
  defaultValue?: string;
  onChange?: (datetime: string) => void;
  onBlur?: () => void;
  placeholder?: string;
  min?: string;
  max?: string;
  disabled?: boolean;
  className?: string;
  required?: boolean;
  'data-testid'?: string;
  yearRange?: { start?: number; end?: number };
}

function parseDateTimeParts(val?: string) {
  if (!val) {
    return { dateStr: '', timeStr: '09:00', parsedDate: null };
  }
  const clean = val.trim();
  const [dPart = '', tPartRaw = '09:00'] = clean.includes('T')
    ? clean.split('T')
    : clean.includes(' ')
    ? clean.split(' ')
    : [clean, '09:00'];
  const timeStr = (tPartRaw || '09:00').slice(0, 5);
  const parsedDate = parseISODate(dPart);
  return { dateStr: dPart, timeStr: timeStr || '09:00', parsedDate };
}

function formatHumanDateTime(val?: string): string {
  const { parsedDate, timeStr } = parseDateTimeParts(val);
  if (!parsedDate) return '';
  const day = String(parsedDate.getDate()).padStart(2, '0');
  const month = MONTHS[parsedDate.getMonth()]?.slice(0, 3) ?? '';
  const year = parsedDate.getFullYear();

  // Format time in 12-hour format
  const [hStr = '09', mStr = '00'] = (timeStr || '09:00').split(':');
  let h = parseInt(hStr, 10);
  if (isNaN(h)) h = 9;
  const ampm = h >= 12 ? 'PM' : 'AM';
  h = h % 12;
  if (h === 0) h = 12;
  const formattedTime = `${h}:${mStr || '00'} ${ampm}`;

  return `${day} ${month} ${year}, ${formattedTime}`;
}

export function DateTimePicker({
  id,
  name,
  value: controlledValue,
  defaultValue,
  onChange,
  onBlur,
  placeholder = 'Select date & time (YYYY-MM-DDTHH:mm)',
  min,
  max,
  disabled = false,
  className,
  required,
  'data-testid': testId,
  yearRange,
}: DateTimePickerProps) {
  const [internalValue, setInternalValue] = React.useState<string>(controlledValue ?? defaultValue ?? '');
  const [open, setOpen] = React.useState(false);
  const containerRef = React.useRef<HTMLDivElement>(null);

  const currentValue = controlledValue !== undefined ? controlledValue : internalValue;
  const { dateStr, timeStr, parsedDate } = parseDateTimeParts(currentValue);

  const [viewYear, setViewYear] = React.useState<number>(() => parsedDate?.getFullYear() ?? new Date().getFullYear());
  const [viewMonth, setViewMonth] = React.useState<number>(() => parsedDate?.getMonth() ?? new Date().getMonth());
  const [selectedTime, setSelectedTime] = React.useState<string>(timeStr || '09:00');

  React.useEffect(() => {
    if (controlledValue !== undefined) {
      setInternalValue(controlledValue);
      const parts = parseDateTimeParts(controlledValue);
      if (parts.parsedDate) {
        setViewYear(parts.parsedDate.getFullYear());
        setViewMonth(parts.parsedDate.getMonth());
      }
      setSelectedTime(parts.timeStr || '09:00');
    }
  }, [controlledValue]);

  // Close popup on outside click
  React.useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    }
    if (open) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [open]);

  const emitChange = (newDateStr: string, newTimeStr: string) => {
    if (!newDateStr) {
      if (controlledValue === undefined) setInternalValue('');
      onChange?.('');
      return;
    }
    const combined = `${newDateStr}T${newTimeStr || '09:00'}`;
    if (controlledValue === undefined) setInternalValue(combined);
    onChange?.(combined);
  };

  const getTodayIso = () => {
    const now = new Date();
    const y = now.getFullYear();
    const m = String(now.getMonth() + 1).padStart(2, '0');
    const d = String(now.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  };

  const getTomorrowIso = () => {
    const d = new Date();
    d.setDate(d.getDate() + 1);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  };

  const getNextSaturdayIso = () => {
    const d = new Date();
    const dayOfWeek = d.getDay();
    const daysUntilSaturday = (6 - dayOfWeek + 7) % 7 || 7;
    d.setDate(d.getDate() + daysUntilSaturday);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  };

  const handleSelectDay = (day: number) => {
    const y = viewYear;
    const m = String(viewMonth + 1).padStart(2, '0');
    const d = String(day).padStart(2, '0');
    const newDate = `${y}-${m}-${d}`;
    emitChange(newDate, selectedTime || '09:00');
  };

  const handleTimeChange = (newTime: string) => {
    setSelectedTime(newTime);
    const d = dateStr || getTodayIso();
    emitChange(d, newTime);
  };

  const handleClear = (e: React.MouseEvent) => {
    e.stopPropagation();
    if (controlledValue === undefined) setInternalValue('');
    onChange?.('');
  };

  // Calendar calculations
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const firstDayOfWeek = new Date(viewYear, viewMonth, 1).getDay();

  const currentYear = new Date().getFullYear();
  const startYear = yearRange?.start ?? currentYear - 5;
  const endYear = yearRange?.end ?? currentYear + 10;
  const yearOptions: number[] = [];
  for (let y = endYear; y >= startYear; y--) {
    yearOptions.push(y);
  }

  const TIME_PRESETS = [
    { label: '09:00 AM', value: '09:00' },
    { label: '10:00 AM', value: '10:00' },
    { label: '11:30 AM', value: '11:30' },
    { label: '02:00 PM', value: '14:00' },
    { label: '03:30 PM', value: '15:30' },
  ];

  return (
    <div ref={containerRef} className={cn('relative inline-block w-full', open && 'z-50', className)}>
      <div className="relative flex items-center w-full">
        {/* Real input for direct typing, automation, and form submissions */}
        <input
          id={id}
          name={name}
          type="text"
          value={currentValue}
          onChange={(e) => {
            const val = e.target.value;
            if (controlledValue === undefined) {
              setInternalValue(val);
            }
            onChange?.(val);
            const parts = parseDateTimeParts(val);
            if (parts.parsedDate) {
              setViewYear(parts.parsedDate.getFullYear());
              setViewMonth(parts.parsedDate.getMonth());
            }
            if (parts.timeStr) {
              setSelectedTime(parts.timeStr);
            }
          }}
          onClick={() => !disabled && setOpen(true)}
          onBlur={onBlur}
          placeholder={placeholder}
          disabled={disabled}
          required={required}
          data-testid={testId}
          className={cn(
            'flex h-9 w-full rounded-md border border-input bg-background pl-3 pr-16 py-1.5 text-xs ring-offset-background transition-colors',
            'file:border-0 file:bg-transparent file:text-sm file:font-medium placeholder:text-muted-foreground',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2',
            disabled && 'cursor-not-allowed opacity-50',
            currentValue ? 'font-mono' : ''
          )}
        />

        <div className="absolute right-2 flex items-center gap-1 text-muted-foreground">
          {currentValue && !disabled && (
            <button
              type="button"
              onClick={handleClear}
              className="rounded p-1 hover:bg-muted hover:text-foreground cursor-pointer transition-colors"
              aria-label="Clear date & time"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          )}

          <button
            type="button"
            onClick={() => !disabled && setOpen(!open)}
            disabled={disabled}
            aria-label="Toggle calendar date & time picker"
            className="rounded p-1 hover:bg-muted hover:text-foreground cursor-pointer transition-colors"
          >
            <CalendarIcon className="h-4 w-4" />
          </button>
        </div>
      </div>

      {/* Human readable helper preview */}
      {currentValue && (
        <p className="mt-1 text-[11px] text-muted-foreground flex items-center gap-1">
          <Clock className="h-3 w-3 text-primary" />
          <span>{formatHumanDateTime(currentValue)}</span>
        </p>
      )}

      {/* Calendar & Time Popover */}
      {open && (
        <div
          className="absolute left-0 z-50 mt-1 w-[320px] rounded-xl border border-border bg-card p-3.5 text-card-foreground shadow-2xl"
          data-testid={`${testId ?? 'datetime-picker'}-popover`}
        >
          {/* Header Controls: Month & Year */}
          <div className="flex items-center justify-between gap-1 pb-2 border-b">
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-7 w-7 p-0 cursor-pointer"
              onClick={() => {
                if (viewMonth === 0) {
                  setViewMonth(11);
                  setViewYear((y) => y - 1);
                } else {
                  setViewMonth((m) => m - 1);
                }
              }}
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>

            <div className="flex items-center gap-1">
              <select
                className="h-7 rounded border border-input bg-background px-1.5 text-xs font-medium focus:outline-none focus:ring-1 focus:ring-ring cursor-pointer"
                value={viewMonth}
                onChange={(e) => setViewMonth(parseInt(e.target.value, 10))}
              >
                {MONTHS.map((m, idx) => (
                  <option key={m} value={String(idx)}>
                    {m}
                  </option>
                ))}
              </select>

              <select
                className="h-7 rounded border border-input bg-background px-1.5 text-xs font-medium focus:outline-none focus:ring-1 focus:ring-ring cursor-pointer"
                value={viewYear}
                onChange={(e) => setViewYear(parseInt(e.target.value, 10))}
              >
                {yearOptions.map((yr) => (
                  <option key={yr} value={String(yr)}>
                    {yr}
                  </option>
                ))}
              </select>
            </div>

            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-7 w-7 p-0 cursor-pointer"
              onClick={() => {
                if (viewMonth === 11) {
                  setViewMonth(0);
                  setViewYear((y) => y + 1);
                } else {
                  setViewMonth((m) => m + 1);
                }
              }}
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>

          {/* Quick Date Presets */}
          <div className="flex items-center justify-between gap-1 py-1.5 border-b text-[11px]">
            <span className="text-muted-foreground">Quick Date:</span>
            <div className="flex items-center gap-1">
              <button
                type="button"
                onClick={() => {
                  const d = getTodayIso();
                  const p = parseISODate(d);
                  if (p) {
                    setViewYear(p.getFullYear());
                    setViewMonth(p.getMonth());
                  }
                  emitChange(d, selectedTime);
                }}
                className="rounded px-1.5 py-0.5 font-medium hover:bg-muted text-primary cursor-pointer"
              >
                Today
              </button>
              <button
                type="button"
                onClick={() => {
                  const d = getTomorrowIso();
                  const p = parseISODate(d);
                  if (p) {
                    setViewYear(p.getFullYear());
                    setViewMonth(p.getMonth());
                  }
                  emitChange(d, selectedTime);
                }}
                className="rounded px-1.5 py-0.5 font-medium hover:bg-muted text-primary cursor-pointer"
              >
                Tomorrow
              </button>
              <button
                type="button"
                onClick={() => {
                  const d = getNextSaturdayIso();
                  const p = parseISODate(d);
                  if (p) {
                    setViewYear(p.getFullYear());
                    setViewMonth(p.getMonth());
                  }
                  emitChange(d, selectedTime);
                }}
                className="rounded px-1.5 py-0.5 font-medium hover:bg-muted text-primary cursor-pointer"
              >
                Saturday
              </button>
            </div>
          </div>

          {/* Days Header */}
          <div className="grid grid-cols-7 gap-1 pt-1 text-center text-[11px] font-semibold text-muted-foreground">
            {DAYS.map((d) => (
              <div key={d} className="h-5 flex items-center justify-center">
                {d}
              </div>
            ))}
          </div>

          {/* Days Grid */}
          <div className="grid grid-cols-7 gap-1 pt-0.5">
            {Array.from({ length: firstDayOfWeek }).map((_, i) => (
              <div key={`empty-${i}`} className="h-7" />
            ))}

            {Array.from({ length: daysInMonth }).map((_, i) => {
              const day = i + 1;
              const y = viewYear;
              const m = String(viewMonth + 1).padStart(2, '0');
              const d = String(day).padStart(2, '0');
              const dayIso = `${y}-${m}-${d}`;

              const isSelected = dateStr === dayIso;
              const isToday = getTodayIso() === dayIso;

              return (
                <button
                  key={`day-${day}`}
                  type="button"
                  onClick={() => handleSelectDay(day)}
                  className={cn(
                    'h-7 w-7 rounded-md text-xs font-medium transition-colors flex items-center justify-center mx-auto cursor-pointer',
                    isSelected
                      ? 'bg-primary text-primary-foreground font-bold hover:bg-primary/90'
                      : 'hover:bg-accent hover:text-accent-foreground',
                    isToday && !isSelected && 'border border-primary text-primary font-semibold'
                  )}
                >
                  {day}
                </button>
              );
            })}
          </div>

          {/* Time Picker Section */}
          <div className="mt-2.5 border-t pt-2 space-y-1.5">
            <div className="flex items-center justify-between text-xs">
              <span className="font-semibold text-foreground flex items-center gap-1">
                <Clock className="h-3.5 w-3.5 text-primary" />
                Exam Start Time:
              </span>
              <input
                type="time"
                value={selectedTime}
                onChange={(e) => handleTimeChange(e.target.value)}
                className="h-7 rounded border border-input bg-background px-2 text-xs font-mono font-medium focus:outline-none focus:ring-1 focus:ring-ring"
              />
            </div>

            {/* Quick Time Slots */}
            <div className="flex flex-wrap items-center gap-1 pt-1">
              {TIME_PRESETS.map((tp) => (
                <button
                  key={tp.value}
                  type="button"
                  onClick={() => handleTimeChange(tp.value)}
                  className={cn(
                    'rounded px-2 py-0.5 text-[11px] font-medium border transition-colors cursor-pointer',
                    selectedTime === tp.value
                      ? 'bg-primary text-primary-foreground border-primary font-bold'
                      : 'bg-muted/40 hover:bg-muted text-muted-foreground hover:text-foreground'
                  )}
                >
                  {tp.label}
                </button>
              ))}
            </div>
          </div>

          {/* Footer Action */}
          <div className="mt-2.5 flex items-center justify-between border-t pt-2 text-xs">
            <span className="text-[11px] text-muted-foreground font-mono">
              {currentValue ? `${currentValue}` : 'No date selected'}
            </span>
            <Button
              type="button"
              size="sm"
              onClick={() => setOpen(false)}
              className="h-6 px-2.5 text-[11px] font-medium"
            >
              Done
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

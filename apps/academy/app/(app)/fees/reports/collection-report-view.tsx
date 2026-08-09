'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { buildCollectionReport, finaliseCashBookDay, type ReportDay } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { ALL_CAMPUSES_VALUE, buildCampusFilterOptions, type CampusOption } from '@/lib/campus-scope';

// Radix's Select.Item rejects an empty-string value outright, but '' is the
// campus-scope module's own "All campuses" sentinel (kept empty so it
// round-trips through a plain FormData field with no UI-library baggage).
// This mapping is purely a Select-widget concern — buildCampusFilterOptions
// itself stays free of it.
const UI_ALL_SENTINEL = '__all__';
const toUiValue = (v: string) => (v === ALL_CAMPUSES_VALUE ? UI_ALL_SENTINEL : v);
const fromUiValue = (v: string) => (v === UI_ALL_SENTINEL ? ALL_CAMPUSES_VALUE : v);

export function CollectionReportView({ campuses, canFinalise }: { campuses: CampusOption[]; canFinalise: boolean }) {
  const [pending, startTransition] = useTransition();
  const [campusId, setCampusId] = useState(campuses[0]?.id ?? ALL_CAMPUSES_VALUE);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [grandTotalPaisa, setGrandTotalPaisa] = useState<number | null>(null);
  const [byDay, setByDay] = useState<ReportDay[]>([]);
  const [finalisedDate, setFinalisedDate] = useState<string | null>(null);

  const campusOptions = buildCampusFilterOptions(campuses);
  // FR-K29's cash_book_day is per-campus (its PK includes campus_id) — a
  // "close the day" action makes no sense while "All campuses" is selected.
  const canFinaliseSelection = canFinalise && campusId !== ALL_CAMPUSES_VALUE;

  const onRun = () => {
    if (!from || !to) {
      toast.error('Choose a date range.');
      return;
    }
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('from', from);
    fd.set('to', to);
    startTransition(async () => {
      const result = await buildCollectionReport({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setGrandTotalPaisa(result.grandTotalPaisa!);
      setByDay(result.byDay!);
    });
  };

  const onFinalise = (bookDate: string) => {
    if (!canFinaliseSelection) return;
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('bookDate', bookDate);
    startTransition(async () => {
      const result = await finaliseCashBookDay({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success('Cash book day finalised.');
      setFinalisedDate(bookDate);
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="report-campus">Campus</Label>
          <Select value={toUiValue(campusId)} onValueChange={(v) => setCampusId(fromUiValue(v))}>
            <SelectTrigger id="report-campus" data-testid="report-campus-trigger">
              <SelectValue placeholder="Select a campus" />
            </SelectTrigger>
            <SelectContent>
              {campusOptions.map((o) => (
                <SelectItem
                  key={o.value || 'all'}
                  value={toUiValue(o.value)}
                  data-testid={o.value === ALL_CAMPUSES_VALUE ? 'report-campus-option-all' : `report-campus-option-${o.value}`}
                >
                  {o.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="report-from">From</Label>
          <Input id="report-from" type="date" data-testid="report-from-input" value={from} onChange={(e) => setFrom(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="report-to">To</Label>
          <Input id="report-to" type="date" data-testid="report-to-input" value={to} onChange={(e) => setTo(e.target.value)} />
        </div>
        <Button type="button" disabled={pending} onClick={onRun} data-testid="report-run-button">
          {pending ? 'Loading…' : 'Run report'}
        </Button>
      </div>

      {grandTotalPaisa !== null && (
        <div className="space-y-2">
          <p className="text-sm font-medium" data-testid="report-grand-total">
            Grand total: PKR {(grandTotalPaisa / 100).toLocaleString()}
          </p>
          {byDay.length === 0 ? (
            <p className="text-sm text-muted-foreground">No collections in this range.</p>
          ) : (
            byDay.map((d) => (
              <Card key={d.value_date} data-testid={`report-day-${d.value_date}`}>
                <CardContent className="space-y-1 p-3 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="font-medium">{d.value_date}</span>
                    <span>PKR {(d.day_total_paisa / 100).toLocaleString()}</span>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {Object.entries(d.by_mode)
                      .map(([mode, v]) => `${mode.replace(/_/g, ' ')}: PKR ${(v.amount_paisa / 100).toLocaleString()} (${v.count})`)
                      .join(' · ')}
                  </p>
                  {canFinaliseSelection && (
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      disabled={pending}
                      onClick={() => onFinalise(d.value_date)}
                      data-testid={`finalise-button-${d.value_date}`}
                    >
                      Finalise cash book day
                    </Button>
                  )}
                  {finalisedDate === d.value_date && (
                    <p className="text-xs text-muted-foreground" data-testid={`finalised-marker-${d.value_date}`}>
                      Finalised.
                    </p>
                  )}
                </CardContent>
              </Card>
            ))
          )}
        </div>
      )}
    </div>
  );
}

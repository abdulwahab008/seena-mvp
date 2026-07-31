'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { loadRegisterRoster, saveAttendanceRegister, type RosterStudent } from './actions';
import { STUDENT_ATTENDANCE_STATUSES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

export function RegisterForm({ campusId, sections }: { campusId: string; sections: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const [sectionId, setSectionId] = useState(sections[0]?.id ?? '');
  const [attendanceDate, setAttendanceDate] = useState(todayIso());
  const [holiday, setHoliday] = useState<string | null>(null);
  const [students, setStudents] = useState<RosterStudent[]>([]);
  const [marks, setMarks] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);

  const onLoad = () => {
    if (!sectionId || !attendanceDate) return;
    startTransition(async () => {
      const result = await loadRegisterRoster(campusId, sectionId, attendanceDate);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setHoliday(result.holiday);
      setStudents(result.students);
      setMarks(Object.fromEntries(result.students.map((s) => [s.enrolmentId, s.currentStatus ?? 'present'])));
      setLoaded(true);
    });
  };

  const onSave = () => {
    const fd = new FormData();
    fd.set('sectionId', sectionId);
    fd.set('attendanceDate', attendanceDate);
    fd.set('marks', JSON.stringify(students.map((s) => ({ enrolmentId: s.enrolmentId, status: marks[s.enrolmentId] ?? 'present' }))));
    startTransition(async () => {
      const result = await saveAttendanceRegister({ error: null, saved: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success(`Register saved — ${result.saved} student(s).`);
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="section">Section</Label>
          <Select value={sectionId} onValueChange={setSectionId}>
            <SelectTrigger id="section" className="w-48" data-testid="register-section-trigger">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {sections.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="attendanceDate">Date</Label>
          <Input
            id="attendanceDate"
            type="date"
            value={attendanceDate}
            onChange={(e) => setAttendanceDate(e.target.value)}
            data-testid="register-date"
          />
        </div>
        <Button type="button" disabled={pending} onClick={onLoad} data-testid="register-load">
          Load register
        </Button>
      </div>

      {loaded && holiday && (
        <p className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800" data-testid="register-holiday-banner">
          {holiday} — this is a declared holiday. The register is read-only.
        </p>
      )}

      {loaded && !holiday && (
        <div className="space-y-2">
          {students.length === 0 ? (
            <p className="text-sm text-muted-foreground">No active students in this section.</p>
          ) : (
            students.map((s) => (
              <Card key={s.enrolmentId} data-testid={`register-row-${s.enrolmentId}`}>
                <CardContent className="flex items-center justify-between p-3 text-sm">
                  <span>
                    {s.name} <span className="text-muted-foreground">({s.grNumber})</span>
                  </span>
                  <Select value={marks[s.enrolmentId] ?? 'present'} onValueChange={(v) => setMarks((m) => ({ ...m, [s.enrolmentId]: v }))}>
                    <SelectTrigger className="w-32" data-testid={`register-status-trigger-${s.enrolmentId}`}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {STUDENT_ATTENDANCE_STATUSES.map((st) => (
                        <SelectItem key={st} value={st}>
                          {st.replace(/_/g, ' ')}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </CardContent>
              </Card>
            ))
          )}
          {students.length > 0 && (
            <Button type="button" disabled={pending} onClick={onSave} data-testid="register-save">
              {pending ? 'Saving…' : 'Save register'}
            </Button>
          )}
        </div>
      )}
    </div>
  );
}

'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { bookInterview } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type ApplicationOption = { id: string; applicationNo: string | null; childName: string };
type PanelOption = { userId: string; fullName: string; appRole: string };

export function BookingForm({ applications, panelMembers }: { applications: ApplicationOption[]; panelMembers: PanelOption[] }) {
  const [pending, startTransition] = useTransition();
  const [applicationId, setApplicationId] = useState('');
  const [panelUserId, setPanelUserId] = useState('');
  const [startsAt, setStartsAt] = useState('');
  const [endsAt, setEndsAt] = useState('');
  const [venue, setVenue] = useState('');
  const [leaveWarning, setLeaveWarning] = useState(false);

  const submit = (confirmDespiteLeave: boolean) => {
    const fd = new FormData();
    fd.set('applicationId', applicationId);
    fd.set('panelUserId', panelUserId);
    fd.set('startsAt', startsAt);
    fd.set('endsAt', endsAt);
    if (venue) fd.set('venue', venue);
    if (confirmDespiteLeave) fd.set('confirmDespiteLeave', 'true');

    startTransition(async () => {
      const result = await bookInterview({ error: null, needsConfirmation: false }, fd);
      if (result.needsConfirmation) {
        setLeaveWarning(true);
        toast.warning(result.error ?? 'This panel member is on leave.');
      } else if (result.error) {
        toast.error(result.error);
      } else {
        toast.success('Interview booked.');
        setApplicationId('');
        setPanelUserId('');
        setStartsAt('');
        setEndsAt('');
        setVenue('');
        setLeaveWarning(false);
      }
    });
  };

  return (
    <div className="space-y-2 rounded-lg border p-4">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
        <div className="space-y-1">
          <Label>Application</Label>
          <Select value={applicationId} onValueChange={setApplicationId}>
            <SelectTrigger data-testid="interview-application-trigger">
              <SelectValue placeholder="Choose an application" />
            </SelectTrigger>
            <SelectContent>
              {applications.map((a) => (
                <SelectItem key={a.id} value={a.id}>
                  {a.childName} ({a.applicationNo})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label>Panel member</Label>
          <Select value={panelUserId} onValueChange={setPanelUserId}>
            <SelectTrigger data-testid="interview-panel-trigger">
              <SelectValue placeholder="Choose a panel member" />
            </SelectTrigger>
            <SelectContent>
              {panelMembers.map((p) => (
                <SelectItem key={p.userId} value={p.userId}>
                  {p.fullName} ({p.appRole.replace(/_/g, ' ')})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="interviewStartsAt">Starts at</Label>
          <Input id="interviewStartsAt" type="datetime-local" value={startsAt} onChange={(e) => setStartsAt(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="interviewEndsAt">Ends at</Label>
          <Input id="interviewEndsAt" type="datetime-local" value={endsAt} onChange={(e) => setEndsAt(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="interviewVenue">Venue</Label>
          <Input id="interviewVenue" value={venue} onChange={(e) => setVenue(e.target.value)} />
        </div>
      </div>
      {leaveWarning && (
        <div className="flex items-center gap-2 rounded border border-amber-400 bg-amber-50 p-2 text-sm" data-testid="leave-warning">
          <span>This panel member has approved leave covering this window.</span>
          <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => submit(true)}>
            Book anyway
          </Button>
        </div>
      )}
      <Button
        type="button"
        disabled={pending || !applicationId || !panelUserId || !startsAt || !endsAt}
        onClick={() => {
          setLeaveWarning(false);
          submit(false);
        }}
      >
        {pending ? 'Booking…' : 'Book interview'}
      </Button>
    </div>
  );
}

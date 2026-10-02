'use client';

import { useActionState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { mapDeviceCode, registerDevice, saveAttendanceRule, setClockOffset, type BiometricState } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: BiometricState = { error: null };

function useToastOnSuccess(state: BiometricState) {
  const router = useRouter();
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
}

export function RegisterDeviceForm({ campusId }: { campusId: string }) {
  const [state, action, pending] = useActionState(registerDevice, initial);
  useToastOnSuccess(state);
  return (
    <div className="space-y-3">
      <form action={action} className="flex flex-wrap items-end gap-3" data-testid="register-device-form">
        <input type="hidden" name="campusId" value={campusId} />
        <div className="space-y-1">
          <Label htmlFor="deviceSerial">Device serial</Label>
          <Input id="deviceSerial" name="deviceSerial" required placeholder="ZK-GATE-01" />
        </div>
        <div className="space-y-1">
          <Label htmlFor="deviceLabel">Label (optional)</Label>
          <Input id="deviceLabel" name="label" placeholder="Main gate" />
        </div>
        <Button type="submit" disabled={pending} data-testid="register-device">
          Register device
        </Button>
      </form>
      {state.error && <p role="alert" className="text-sm text-destructive">{state.error}</p>}
      {state.apiKey && (
        <div className="rounded-md border border-warning bg-warning-muted p-3 text-sm" data-testid="device-key-once">
          <p className="font-medium">Device key for {state.serial} — copy it now, it is not shown again.</p>
          <code className="mt-1 block break-all font-mono text-xs" data-testid="device-key">{state.apiKey}</code>
          <p className="mt-2 text-xs text-muted-foreground">
            The on-premise agent signs each batch with HMAC-SHA256 using sha256(this key) as the secret, and sends it to <code>/api/webhooks/biometric</code> with the header <code>x-device-serial</code>.
          </p>
        </div>
      )}
    </div>
  );
}

export function MapCodeForm({ devices, staff, defaultDeviceId, defaultCode }: { devices: { id: string; serial: string }[]; staff: { id: string; name: string }[]; defaultDeviceId?: string; defaultCode?: string }) {
  const [state, action, pending] = useActionState(mapDeviceCode, initial);
  useToastOnSuccess(state);
  return (
    <form action={action} className="flex flex-wrap items-end gap-3" data-testid="map-code-form">
      <div className="space-y-1">
        <Label>Device</Label>
        <select name="deviceId" defaultValue={defaultDeviceId} required aria-label="Device" className="h-9 rounded-md border bg-background px-2 text-sm">
          {devices.map((d) => (
            <option key={d.id} value={d.id}>
              {d.serial}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label>Code on device</Label>
        <Input name="code" required defaultValue={defaultCode} aria-label="Code on device" className="w-32" />
      </div>
      <div className="space-y-1">
        <Label>Staff member</Label>
        <select name="staffId" required aria-label="Staff member" className="h-9 rounded-md border bg-background px-2 text-sm">
          <option value="">Choose…</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
      </div>
      <Button type="submit" size="sm" disabled={pending} data-testid="map-code">
        Map code
      </Button>
      {state.error && <p role="alert" className="w-full text-sm text-destructive">{state.error}</p>}
    </form>
  );
}

export function ClockOffsetForm({ deviceId, current }: { deviceId: string; current: number }) {
  const [state, action, pending] = useActionState(setClockOffset, initial);
  useToastOnSuccess(state);
  return (
    <form action={action} className="flex items-center gap-2">
      <input type="hidden" name="deviceId" value={deviceId} />
      <Input name="offsetSeconds" type="number" defaultValue={current} aria-label="Clock offset in seconds" className="h-8 w-28" />
      <Button type="submit" size="sm" variant="outline" disabled={pending}>
        Save offset
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}

export function AttendanceRuleForm({ campusId, startTime, graceMinutes }: { campusId: string; startTime: string; graceMinutes: number }) {
  const [state, action, pending] = useActionState(saveAttendanceRule, initial);
  useToastOnSuccess(state);
  return (
    <form action={action} className="flex flex-wrap items-end gap-3" data-testid="attendance-rule-form">
      <input type="hidden" name="campusId" value={campusId} />
      <div className="space-y-1">
        <Label htmlFor="startTime">Staff start time</Label>
        <Input id="startTime" name="startTime" type="time" defaultValue={startTime} required />
      </div>
      <div className="space-y-1">
        <Label htmlFor="graceMinutes">Grace period (minutes)</Label>
        <Input id="graceMinutes" name="graceMinutes" type="number" min={0} max={240} defaultValue={graceMinutes} required />
      </div>
      <Button type="submit" disabled={pending}>
        Save
      </Button>
      {state.error && <p role="alert" className="w-full text-sm text-destructive">{state.error}</p>}
    </form>
  );
}

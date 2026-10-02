import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, todayKarachi } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AttendanceRuleForm, ClockOffsetForm, MapCodeForm, RegisterDeviceForm } from './biometric-forms';

export const dynamic = 'force-dynamic';

function daysAgo(iso: string, n: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}

export default async function BiometricPage({ searchParams }: { searchParams: Promise<{ campus?: string }> }) {
  const sp = await searchParams;
  const actor = await getCurrentActor();
  const canWrite = isHrWriter(actor?.role);
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').order('name');
  const campus = (campuses ?? []).find((c) => c.id === sp.campus) ?? (campuses ?? [])[0];
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is available to your account.</p>;

  const today = todayKarachi();
  const [{ data: devices }, { data: rule }, { data: staff }, exceptions, unmatched, { data: maps }] = await Promise.all([
    supabase.from('biometric_device').select('id, device_serial, label, clock_offset_seconds, last_seen_at, is_active').eq('campus_id', campus.id).order('device_serial'),
    supabase.from('campus_staff_attendance_rule').select('start_time, late_grace_minutes').eq('campus_id', campus.id).maybeSingle(),
    supabase.from('staff').select('id, full_name, employee_code').eq('campus_id', campus.id).neq('employment_status', 'exited').order('full_name'),
    supabase.rpc('list_biometric_exceptions', { p_campus_id: campus.id, p_from: daysAgo(today, 14), p_to: today }),
    supabase.rpc('list_unmatched_biometric_punches', { p_campus_id: campus.id }),
    supabase.from('staff_device_map').select('staff_id, device_id, staff_device_code'),
  ]);
  const deviceList = (devices ?? []).map((d) => ({ id: d.id, serial: d.device_serial }));
  const staffOptions = (staff ?? []).map((s) => ({ id: s.id, name: `${s.full_name} (${s.employee_code})` }));
  const staffName = new Map((staff ?? []).map((s) => [s.id, s.full_name]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Biometric attendance</h1>
        <p className="text-sm text-muted-foreground">
          FR-D08 — punches pushed by the campus fingerprint device become staff attendance automatically. Retried or late batches never create duplicates; unknown codes wait below until you map them.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Start time and grace period — {campus.name}</CardTitle>
        </CardHeader>
        <CardContent>
          {canWrite ? (
            <AttendanceRuleForm campusId={campus.id} startTime={(rule?.start_time ?? '08:00:00').slice(0, 5)} graceMinutes={rule?.late_grace_minutes ?? 10} />
          ) : (
            <p className="text-sm">
              Staff are on time until {(rule?.start_time ?? '08:00:00').slice(0, 5)} plus {rule?.late_grace_minutes ?? 10} minutes.
            </p>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Devices</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          {(devices ?? []).length === 0 && <p className="text-muted-foreground">No device registered for this campus.</p>}
          {(devices ?? []).map((d) => (
            <div key={d.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-3" data-testid="device-row">
              <div>
                <p className="font-medium">
                  {d.device_serial} {d.label ? <span className="text-muted-foreground">· {d.label}</span> : null}
                </p>
                <p className="text-xs text-muted-foreground">
                  {d.last_seen_at ? `Last batch ${new Date(d.last_seen_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}` : 'No batch received yet'} ·{' '}
                  {(maps ?? []).filter((m) => m.device_id === d.id).length} staff mapped
                </p>
              </div>
              {canWrite ? <ClockOffsetForm deviceId={d.id} current={d.clock_offset_seconds} /> : <Badge variant="outline">clock offset {d.clock_offset_seconds}s</Badge>}
            </div>
          ))}
          {canWrite && <RegisterDeviceForm campusId={campus.id} />}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Unmatched punches</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="unmatched-list">
          {(unmatched.data ?? []).length === 0 && <p className="text-muted-foreground">Every punch received so far belongs to a mapped staff member.</p>}
          {(unmatched.data ?? []).map((u) => (
            <div key={`${u.device_id}-${u.staff_device_code}`} className="space-y-2 border-b pb-3" data-testid="unmatched-row">
              <p>
                Code <strong>{u.staff_device_code}</strong> on {u.device_serial}: {Number(u.punches)} punch(es), last {new Date(u.last_punch).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}
              </p>
              {canWrite && <MapCodeForm devices={deviceList} staff={staffOptions} defaultDeviceId={u.device_id} defaultCode={u.staff_device_code} />}
            </div>
          ))}
        </CardContent>
      </Card>

      {canWrite && deviceList.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Map a device code to a staff member</CardTitle>
          </CardHeader>
          <CardContent>
            <MapCodeForm devices={deviceList} staff={staffOptions} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Attendance exceptions (last 14 days)</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="exception-list">
          {(exceptions.data ?? []).length === 0 && <p className="text-muted-foreground">No exceptions to review.</p>}
          {(exceptions.data ?? []).map((x) => (
            <div key={`${x.staff_id}-${x.att_date}`} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="exception-row">
              <span>
                {x.att_date} · {x.full_name ?? staffName.get(x.staff_id)} <span className="text-xs text-muted-foreground">({x.employee_code})</span>
              </span>
              <span className="flex items-center gap-2">
                <Badge variant={x.status === 'late' ? 'warning' : 'success'}>{x.status}</Badge>
                <Badge variant="warning">{x.anomaly === 'missing_out_punch' ? 'No sign-out punch' : x.anomaly}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

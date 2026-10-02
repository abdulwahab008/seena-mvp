import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ActionButton, SpecForm } from '@/components/spec-form';
import { currentRole, loose, pickCampus } from '@/lib/transport/rpc';
import { saveHostelSettings, signOutVisitor } from './actions';
import { VisitorForm } from './visitor-form';

export const dynamic = 'force-dynamic';

type Open = { id: string; student_name: string; gr_number: string; visitor_name: string; visitor_cnic: string; relationship: string | null; entered_at: string; verified: boolean; photo_path: string | null };
const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Karachi' });

export default async function VisitorsPage({ searchParams }: { searchParams: Promise<{ campus_id?: string }> }) {
  const sp = await searchParams;
  const supabase = loose(await supabaseServer());
  const [campus, role] = await Promise.all([pickCampus(supabase, sp.campus_id), currentRole(supabase)]);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;
  const [{ data }, { data: settings }] = await Promise.all([
    supabase.from('v_hostel_open_visits').select('id, student_name, gr_number, visitor_name, visitor_cnic, relationship, entered_at, verified, photo_path').eq('campus_id', campus.id).order('entered_at', { ascending: false }),
    supabase.from('tenant_setting').select('key, value').in('key', ['hostel.visiting_close', 'hostel.visitor_retention_days', 'hostel.mess_notice_hours']),
  ]);
  const open = (data ?? []) as Open[];
  const cfg = new Map(((settings ?? []) as { key: string; value: unknown }[]).map((s) => [s.key, s.value]));
  const photos = new Map<string, string>();
  for (const v of open) {
    if (!v.photo_path) continue;
    const { data: signed } = await supabase.storage.from('hostel-visitor-photos').createSignedUrl(v.photo_path, 300);
    if (signed?.signedUrl) photos.set(v.id, signed.signedUrl);
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Hostel visitors</h1>
        <p className="text-sm text-muted-foreground">
          FR-Q04 — who is inside the premises right now. Visitor details and photographs are kept for {String(cfg.get('hostel.visitor_retention_days') ?? 180)} days and are never visible to parents or students.
        </p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Log an entry</CardTitle>
        </CardHeader>
        <CardContent>
          <VisitorForm />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Inside now ({open.length})</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm" data-testid="open-visits">
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="py-1">Entered</th>
                <th>Visitor</th>
                <th>CNIC</th>
                <th>Visiting</th>
                <th>Relationship</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {open.map((v) => (
                <tr key={v.id} className={`border-t ${v.verified ? '' : 'bg-warning-muted'}`} data-testid="open-visit-row">
                  <td className="py-1">{clock(v.entered_at)}</td>
                  <td>
                    {v.visitor_name} {photos.has(v.id) && <a className="ms-1 underline" href={photos.get(v.id)} target="_blank" rel="noreferrer">photo</a>}
                  </td>
                  <td>{v.visitor_cnic}</td>
                  <td>
                    {v.student_name} ({v.gr_number})
                  </td>
                  <td>
                    {v.relationship ?? '-'} {v.verified ? <Badge variant="success">verified</Badge> : <Badge variant="warning">unverified</Badge>}
                  </td>
                  <td>
                    <ActionButton label="Sign out" testId={`signout-${v.visitor_name}`} action={signOutVisitor} args={[v.id]} />
                  </td>
                </tr>
              ))}
              {open.length === 0 && (
                <tr>
                  <td colSpan={6} className="py-2 text-muted-foreground">
                    Nobody is inside.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
      {['owner', 'super_admin', 'principal'].includes(role) && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Hostel settings</CardTitle>
          </CardHeader>
          <CardContent>
            <SpecForm
              testId="hostel-settings-form"
              submitLabel="Save settings"
              action={saveHostelSettings}
              resetOnSuccess={false}
              columns={3}
              fields={[
                { name: 'visitingClose', label: 'Closing time (visitors out by)', defaultValue: String(cfg.get('hostel.visiting_close') ?? '21:00'), required: true },
                { name: 'retentionDays', label: 'Keep visitor records (days)', type: 'number', defaultValue: String(cfg.get('hostel.visitor_retention_days') ?? 180), required: true },
                { name: 'messNoticeHours', label: 'Mess-off notice (hours)', type: 'number', defaultValue: String(cfg.get('hostel.mess_notice_hours') ?? 24), required: true },
              ]}
            />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

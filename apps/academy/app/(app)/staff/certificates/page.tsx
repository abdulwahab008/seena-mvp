import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { IssueCertificateForm, TemplateForm } from './certificate-forms';

export const dynamic = 'force-dynamic';

export default async function StaffCertificatesPage() {
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  const canIssue = isHrWriter(actor?.role);

  const [{ data: certs }, { data: staff }, { data: templates }] = await Promise.all([
    supabase
      .from('staff_certificate')
      .select('id, certificate_no, cert_type, issued_at, override_id, staff:staff_id(full_name, employee_code)')
      .order('issued_at', { ascending: false })
      .limit(200),
    canIssue ? supabase.from('staff').select('id, full_name, employee_code').order('full_name') : Promise.resolve({ data: [] as { id: string; full_name: string; employee_code: string }[] }),
    canIssue ? supabase.from('staff_certificate_template').select('cert_type, title, body_html, number_format').order('cert_type') : Promise.resolve({ data: [] as { cert_type: string; title: string; body_html: string; number_format: string }[] }),
  ]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff certificates</h1>
        <p className="text-sm text-muted-foreground">
          FR-D18 — experience, service and no-objection certificates on the school letterhead, numbered without gaps. What a certificate says is frozen when it is issued, so a reprint is identical and uses no new number.
        </p>
      </div>

      {canIssue && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Issue a certificate</CardTitle>
          </CardHeader>
          <CardContent>
            <IssueCertificateForm staff={(staff ?? []).map((s) => ({ id: s.id, name: `${s.full_name} (${s.employee_code})` }))} isOwner={actor?.role === 'owner' || actor?.role === 'super_admin'} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{canIssue || ['principal'].includes(actor?.role ?? '') ? 'Issued certificates' : 'My certificates'}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="certificate-list">
          {(certs ?? []).length === 0 && <p className="text-muted-foreground">No certificates have been issued.</p>}
          {(certs ?? []).map((c) => (
            <div key={c.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="certificate-row">
              <span>
                <strong>{c.certificate_no}</strong> · {c.cert_type} · {one(c.staff)?.full_name}{' '}
                <span className="text-xs text-muted-foreground">issued {new Date(c.issued_at).toLocaleDateString('en-PK', { timeZone: 'Asia/Karachi' })}{c.override_id ? ' · released by Owner override' : ''}</span>
              </span>
              <a href={`/api/staff-certificates/${c.id}/pdf`} target="_blank" rel="noreferrer" className="text-primary underline" data-testid="print-certificate">
                Print / download PDF
              </a>
            </div>
          ))}
        </CardContent>
      </Card>

      {canIssue && (templates ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Certificate wording</CardTitle>
          </CardHeader>
          <CardContent>
            <TemplateForm templates={(templates ?? []).map((t) => ({ certType: t.cert_type, title: t.title, bodyHtml: t.body_html, numberFormat: t.number_format }))} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

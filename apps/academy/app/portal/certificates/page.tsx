import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t, type MessageKey } from '@/lib/i18n/messages';
import { certificateDownloadPath } from '@/lib/certificates/issue';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CertificateRequestForm } from './request-form';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function PortalCertificatesPage() {
  const lang = await getLang();
  const supabase = await supabaseServer();
  const [{ data: children }, { data: purposes }, { data: requests }] = await Promise.all([
    supabase.from('student').select('id, name_en, name_ur').order('name_en'),
    supabase.from('certificate_request_purpose').select('code, label_en, label_ur, requires_justification').order('sort_order'),
    supabase
      .from('certificate_request')
      .select('id, purpose, status, created_at, reject_reason, certificate_issue_id, student:student_id(name_en, name_ur)')
      .order('created_at', { ascending: false })
      .limit(30),
  ]);
  const purposeLabel = new Map((purposes ?? []).map((p) => [p.code, lang === 'ur' ? p.label_ur : p.label_en]));

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-bold tracking-tight">{t(lang, 'cert.title')}</h2>
        <p className="text-sm text-muted-foreground">{t(lang, 'cert.intro')}</p>
      </div>

      <Card>
        <CardContent className="pt-6">
          <CertificateRequestForm
            kids={(children ?? []).map((c) => ({ id: c.id, name: lang === 'ur' && c.name_ur ? c.name_ur : c.name_en }))}
            purposes={(purposes ?? []).map((p) => ({ code: p.code, label: lang === 'ur' ? p.label_ur : p.label_en, requiresJustification: p.requires_justification }))}
            strings={{
              child: t(lang, 'cert.child'),
              purpose: t(lang, 'cert.purpose'),
              justification: t(lang, 'cert.justification'),
              submit: t(lang, 'cert.submit'),
              submitted: t(lang, 'cert.submitted'),
              errChoose: t(lang, 'cert.errChoose'),
              limit: t(lang, 'cert.limit'),
              errNotFound: t(lang, 'cert.errNotFound'),
            }}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{t(lang, 'cert.mine')}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="cert-request-list">
          {(requests ?? []).length === 0 && <p className="text-muted-foreground">{t(lang, 'cert.none')}</p>}
          {(requests ?? []).map((r) => {
            const stu = one(r.student);
            return (
              <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="cert-request-row">
                <span>
                  {lang === 'ur' && stu?.name_ur ? stu.name_ur : stu?.name_en} · {purposeLabel.get(r.purpose) ?? r.purpose}
                </span>
                <span className="flex items-center gap-2">
                  <Badge variant={r.status === 'issued' ? 'success' : 'outline'}>{t(lang, `cert.status.${r.status}` as MessageKey)}</Badge>
                  {r.status === 'issued' && r.certificate_issue_id && (
                    <a className="underline" href={certificateDownloadPath(r.certificate_issue_id)} data-testid="cert-download">
                      {t(lang, 'cert.download')}
                    </a>
                  )}
                </span>
              </div>
            );
          })}
        </CardContent>
      </Card>
    </div>
  );
}

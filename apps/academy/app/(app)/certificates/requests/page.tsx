import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { RequestQueue, type PendingRequest } from './request-queue';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function CertificateRequestsPage() {
  const supabase = await supabaseServer();
  const [{ data: pending }, { data: decided }, { data: purposes }] = await Promise.all([
    supabase
      .from('certificate_request')
      .select('id, purpose, justification, created_at, student:student_id(name_en, gr_number)')
      .eq('status', 'pending')
      .order('created_at'),
    supabase
      .from('certificate_request')
      .select('id, purpose, status, decided_at, reject_reason, student:student_id(name_en, gr_number)')
      .neq('status', 'pending')
      .order('decided_at', { ascending: false })
      .limit(30),
    supabase.from('certificate_request_purpose').select('code, label_en'),
  ]);
  const label = new Map((purposes ?? []).map((p) => [p.code, p.label_en]));
  const queue: PendingRequest[] = (pending ?? []).map((r) => ({
    id: r.id,
    student: one(r.student)?.name_en ?? '',
    gr: one(r.student)?.gr_number ?? '',
    purpose: label.get(r.purpose) ?? r.purpose,
    justification: r.justification,
    requestedAt: r.created_at,
  }));

  return (
    <div className="space-y-6">
      <PageHeader
        title="Bonafide requests"
        description="FR-T06 — requests from guardians in the parent portal. Approving issues the certificate, stores the PDF and queues a WhatsApp message with a 7-day link. A guardian can make at most 3 requests a day."
      />
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Waiting for a decision</CardTitle>
        </CardHeader>
        <CardContent>
          <RequestQueue requests={queue} />
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Recently decided</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm" data-testid="cert-decided">
          {(decided ?? []).map((r) => (
            <p key={r.id} className="flex items-center justify-between border-b py-1" data-testid="cert-decided-row">
              <span>
                {one(r.student)?.name_en} ({one(r.student)?.gr_number}) · {label.get(r.purpose) ?? r.purpose}
                {r.reject_reason ? ` — ${r.reject_reason}` : ''}
              </span>
              <Badge variant={r.status === 'issued' ? 'success' : 'outline'}>{r.status}</Badge>
            </p>
          ))}
          {(decided ?? []).length === 0 && <p className="text-muted-foreground">Nothing decided yet.</p>}
        </CardContent>
      </Card>
    </div>
  );
}

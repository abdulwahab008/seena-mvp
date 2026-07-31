import { supabaseServer } from '@/lib/supabase/server';
import { ApplicationList, type ApplicationRow } from './application-list';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function ApplicationsPage() {
  const supabase = await supabaseServer();

  const [{ data: apps }, { data: offers }, { data: waitlistRows }, { data: documentRows }] = await Promise.all([
    supabase
      .from('admission_application')
      .select(
        'id, application_no, status, campus_id, session_id, class_applied_id, checklist_snapshot, admission_enquiry(child_name), class_level(name_en)'
      )
      .order('submitted_at', { ascending: false }),
    supabase
      .from('admission_offer')
      .select('id, application_id, status, expires_at')
      .order('issued_at', { ascending: false }),
    supabase.from('admission_waitlist').select('id, application_id, position, status').neq('status', 'withdrawn'),
    supabase
      .from('admission_document')
      .select('id, application_id, doc_type, status, reject_reason, b_form_no, created_at')
      .order('created_at', { ascending: false }),
  ]);

  const latestOfferByApp = new Map<string, { id: string; status: string; expires_at: string }>();
  for (const o of offers ?? []) {
    if (!latestOfferByApp.has(o.application_id)) latestOfferByApp.set(o.application_id, o);
  }
  const waitlistByApp = new Map<string, { id: string; position: number | null; status: string }>();
  for (const w of waitlistRows ?? []) waitlistByApp.set(w.application_id, w);
  const documentsByApp = new Map<string, ApplicationRow['documents']>();
  for (const d of documentRows ?? []) {
    const list = documentsByApp.get(d.application_id) ?? [];
    list.push({ id: d.id, docType: d.doc_type, status: d.status, rejectReason: d.reject_reason, bFormNo: d.b_form_no });
    documentsByApp.set(d.application_id, list);
  }

  const rows: ApplicationRow[] = await Promise.all(
    (apps ?? []).map(async (a) => {
      const offer = latestOfferByApp.get(a.id) ?? null;
      let availableSeats: number | null = null;
      if (!offer && (a.status === 'submitted' || a.status === 'under_review')) {
        const { data } = await supabase.rpc('available_seats', {
          p_class_level_id: a.class_applied_id,
          p_session_id: a.session_id,
          p_campus_id: a.campus_id,
        });
        availableSeats = data ?? 0;
      }
      return {
        id: a.id,
        applicationNo: a.application_no,
        status: a.status,
        childName: one(a.admission_enquiry)?.child_name ?? 'Unknown',
        className: one(a.class_level)?.name_en ?? 'Unknown',
        offer,
        availableSeats,
        waitlist: waitlistByApp.get(a.id) ?? null,
        checklistSnapshot: (a.checklist_snapshot ?? []) as { doc_type: string; is_mandatory: boolean; min_count: number }[],
        documents: documentsByApp.get(a.id) ?? [],
      };
    })
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Applications</h1>
        <p className="text-sm text-muted-foreground">
          FR-B08/B15/B16/B06 — issue offers against live seat availability and record responses.
        </p>
      </div>
      <ApplicationList applications={rows} />
    </div>
  );
}

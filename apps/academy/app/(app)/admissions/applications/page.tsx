import { supabaseServer } from '@/lib/supabase/server';
import { ApplicationList, type ApplicationRow } from './application-list';
import { QuickAdmissionModal } from '@/components/admissions/quick-admission-modal';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function ApplicationsPage() {
  const supabase = await supabaseServer();

  const [
    { data: apps },
    { data: offers },
    { data: waitlistRows },
    { data: documentRows },
    { data: campuses },
    { data: sessions },
    { data: classLevels },
  ] = await Promise.all([
    supabase
      .from('admission_application')
      .select(
        'id, application_no, status, campus_id, session_id, class_applied_id, checklist_snapshot, admission_enquiry(child_name), class_level(name_en)'
      )
      .order('submitted_at', { ascending: false }),
    supabase
      .from('admission_offer')
      .select('id, application_id, status, expires_at, admission_fee_amount, expiry_paused_at, expiry_pause_reason')
      .order('issued_at', { ascending: false }),
    supabase.from('admission_waitlist').select('id, application_id, position, status').neq('status', 'withdrawn'),
    supabase
      .from('admission_document')
      .select('id, application_id, doc_type, status, reject_reason, b_form_no, created_at')
      .order('created_at', { ascending: false }),
    supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
  ]);

  const latestOfferByApp = new Map<
    string,
    { id: string; status: string; expires_at: string; admission_fee_amount: number; expiry_paused_at: string | null; expiry_pause_reason: string | null }
  >();
  for (const o of offers ?? []) {
    if (!latestOfferByApp.has(o.application_id)) latestOfferByApp.set(o.application_id, o);
  }

  const acceptedOfferIds = (offers ?? []).filter((o) => o.status === 'accepted').map((o) => o.id);
  const [{ data: paymentRows }, { data: waiverRows }, { data: sectionRows }] = await Promise.all([
    acceptedOfferIds.length
      ? supabase
          .from('admission_fee_payment')
          .select('id, offer_id, amount_paisa, mode, status, consumed_by_enrolment_id')
          .in('offer_id', acceptedOfferIds)
          .order('recorded_at', { ascending: false })
      : Promise.resolve({ data: [] }),
    acceptedOfferIds.length
      ? supabase
          .from('admission_fee_waiver')
          .select('id, offer_id, reason, consumed_by_enrolment_id')
          .in('offer_id', acceptedOfferIds)
          .order('approved_at', { ascending: false })
      : Promise.resolve({ data: [] }),
    supabase.from('class_section').select('id, campus_id, session_id, class_level_id, name').eq('is_active', true),
  ]);

  const paymentsByOffer = new Map<string, ApplicationRow['payments']>();
  for (const p of paymentRows ?? []) {
    const list = paymentsByOffer.get(p.offer_id) ?? [];
    list.push({ id: p.id, amountPaisa: p.amount_paisa, mode: p.mode, status: p.status, consumed: p.consumed_by_enrolment_id !== null });
    paymentsByOffer.set(p.offer_id, list);
  }
  const waiversByOffer = new Map<string, ApplicationRow['waivers']>();
  for (const w of waiverRows ?? []) {
    const list = waiversByOffer.get(w.offer_id) ?? [];
    list.push({ id: w.id, reason: w.reason, consumed: w.consumed_by_enrolment_id !== null });
    waiversByOffer.set(w.offer_id, list);
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
      const sections = (sectionRows ?? [])
        .filter((s) => s.campus_id === a.campus_id && s.session_id === a.session_id && s.class_level_id === a.class_applied_id)
        .map((s) => ({ id: s.id, name: s.name }));

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
        payments: offer ? (paymentsByOffer.get(offer.id) ?? []) : [],
        waivers: offer ? (waiversByOffer.get(offer.id) ?? []) : [],
        sections,
      };
    })
  );

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Applications</h1>
          <p className="text-sm text-muted-foreground">
            FR-B08/B15/B16/B06 — issue offers against live seat availability and record responses.
          </p>
        </div>
        <QuickAdmissionModal
          campuses={campuses ?? []}
          sessions={sessions ?? []}
          classLevels={classLevels ?? []}
          sections={(sectionRows ?? []).map((s) => ({
            id: s.id,
            name: s.name,
            class_level_id: s.class_level_id,
            campus_id: s.campus_id,
            session_id: s.session_id,
          }))}
        />
      </div>
      <ApplicationList applications={rows} />
    </div>
  );
}

import { supabaseServer } from '@/lib/supabase/server';
import { ChallanGenerator, type ChallanRow, type BatchErrorRow, type BatchRow } from './challan-generator';
import { ChallanTemplateForm, type ChallanTemplateData } from './challan-template-form';

type ChallanQueryRow = {
  id: string;
  challan_no: string;
  billing_period: string;
  gross_paisa: number;
  concession_paisa: number;
  arrears_paisa: number;
  arrears_source: { enrolment_id: string; session_id: string; amount_paisa: number }[];
  net_paisa: number;
  status: string;
};

export default async function ChallansPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id').eq('is_current', true).order('starts_on', { ascending: false }),
  ]);

  const campus = campuses?.[0];
  const session = sessions?.[0];

  let batch: BatchRow = null;
  let batchErrors: BatchErrorRow[] = [];
  let challans: ChallanRow[] = [];
  let template: ChallanTemplateData = null;
  let canConfigureTemplate = false;

  if (campus && session) {
    const { data: batchRow } = await supabase
      .from('fee_challan_batch')
      .select('id, billing_period, generated_count, skipped_count, failed_count')
      .eq('campus_id', campus.id)
      .eq('session_id', session.id)
      .order('started_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (batchRow) {
      batch = {
        id: batchRow.id,
        billingPeriod: batchRow.billing_period,
        generatedCount: batchRow.generated_count,
        skippedCount: batchRow.skipped_count,
        failedCount: batchRow.failed_count,
      };

      const { data: errRows } = await supabase.from('fee_challan_batch_error').select('id, reason').eq('batch_id', batchRow.id);
      batchErrors = errRows ?? [];
    }

    const { data: challanRawRows } = await supabase
      .from('fee_challan')
      .select('id, challan_no, billing_period, gross_paisa, concession_paisa, arrears_paisa, arrears_source, net_paisa, status')
      .eq('campus_id', campus.id)
      .eq('session_id', session.id)
      .order('created_at', { ascending: false })
      .limit(100);

    const challanRows = (challanRawRows ?? []) as unknown as ChallanQueryRow[];

    // FR-K24 AC4: arrears carried from a PRIOR session is attributed to it
    // by name. Same-session carry-forward needs no label — it is just last
    // month, on the session the reader is already looking at.
    const priorSessionIds = [
      ...new Set(
        challanRows.flatMap((c) => c.arrears_source.map((s) => s.session_id)).filter((id) => id !== session.id),
      ),
    ];
    const sessionNames = new Map<string, string>();
    if (priorSessionIds.length > 0) {
      const { data: priorSessions } = await supabase.from('academic_session').select('id, name').in('id', priorSessionIds);
      for (const s of priorSessions ?? []) sessionNames.set(s.id, s.name);
    }

    challans = challanRows.map((c) => ({
      id: c.id,
      challanNo: c.challan_no,
      billingPeriod: c.billing_period,
      grossPaisa: c.gross_paisa,
      concessionPaisa: c.concession_paisa,
      arrearsPaisa: c.arrears_paisa,
      arrearsFrom: c.arrears_source
        .filter((s) => s.session_id !== session.id)
        .map((s) => ({ sessionName: sessionNames.get(s.session_id) ?? s.session_id, amountPaisa: s.amount_paisa })),
      netPaisa: c.net_paisa,
      status: c.status,
    }));

    const { data: templateRow } = await supabase
      .from('challan_template')
      .select('bank_name, bank_account_title, bank_account_no, footer_note_en')
      .eq('campus_id', campus.id)
      .maybeSingle();
    template = templateRow
      ? {
          bankName: templateRow.bank_name,
          bankAccountTitle: templateRow.bank_account_title,
          bankAccountNo: templateRow.bank_account_no,
          footerNoteEn: templateRow.footer_note_en,
        }
      : null;

    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
    canConfigureTemplate = appUser?.app_role === 'super_admin' || appUser?.app_role === 'owner';
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Monthly challans</h1>
        <p className="text-sm text-muted-foreground">
          FR-K09 — generate a challan per active enrolment for a billing month. Re-running a month is a no-op for challans that already exist.
        </p>
      </div>
      {campus && session ? (
        <>
          {canConfigureTemplate && (
            <div className="space-y-2">
              <h2 className="text-lg font-medium">Challan template (FR-K11)</h2>
              <p className="text-sm text-muted-foreground">
                Bank details for this campus&apos;s challan copies. No PDF renderer exists yet — see &quot;Preview PDF payload&quot; below
                for the data a future renderer would consume.
              </p>
              <ChallanTemplateForm campusId={campus.id} template={template} />
            </div>
          )}
          <ChallanGenerator campusId={campus.id} sessionId={session.id} batch={batch} batchErrors={batchErrors} challans={challans} />
        </>
      ) : (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      )}
    </div>
  );
}

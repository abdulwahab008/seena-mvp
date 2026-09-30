import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ChallanActionsClient } from './challan-actions-client';
import { PayPanel } from './pay-panel';

/**
 * FR-N04: Fee dues view with pay action for parents/guardians.
 *
 * Surfaces fee challans, line item breakdowns, outstanding dues,
 * payment deadlines, and payment mechanisms (online 1Bill/mobile & bank challan slip).
 */

type SearchParams = {
  enrolment?: string;
};

type Child = {
  enrolmentId: string;
  studentId: string;
  studentName: string;
  sectionLabel: string;
};

type FeeChallan = {
  id: string;
  challan_no: string;
  billing_period: string;
  issue_date: string;
  due_date: string;
  gross_paisa: number;
  concession_paisa: number;
  arrears_paisa: number;
  net_paisa: number;
  status: 'unpaid' | 'part_paid' | 'paid' | 'cancelled';
  campus_id: string;
};

type FeeLine = {
  id: string;
  challan_id: string;
  amount_paisa: number;
  concession_paisa: number;
  net_paisa: number;
  line_type: string;
  fee_head_id: string;
};

type FeeHead = {
  id: string;
  name_en: string;
  code: string;
};

const STATUS_CONFIG: Record<
  string,
  { label: string; badgeClass: string }
> = {
  paid: {
    label: 'Paid',
    badgeClass: 'bg-emerald-100 text-emerald-800 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-400 dark:border-emerald-800',
  },
  unpaid: {
    label: 'Unpaid',
    badgeClass: 'bg-rose-100 text-rose-800 border-rose-200 dark:bg-rose-950/40 dark:text-rose-400 dark:border-rose-800',
  },
  part_paid: {
    label: 'Partially Paid',
    badgeClass: 'bg-amber-100 text-amber-800 border-amber-200 dark:bg-amber-950/40 dark:text-amber-400 dark:border-amber-800',
  },
  cancelled: {
    label: 'Cancelled',
    badgeClass: 'bg-muted text-muted-foreground border-muted',
  },
};

export default async function PortalFeesPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  // 1. Fetch children enrolled for this guardian
  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student_id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');

  const children: Child[] = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return {
        enrolmentId: e.id,
        studentId: student.id,
        studentName: student.name_en,
        sectionLabel: `${level?.name_en ?? ''} · ${section.name}`,
      };
    })
    .filter((c): c is Child => !!c);

  const child = children.find((c) => c.enrolmentId === params.enrolment) ?? children[0];

  // 2. Fetch challans for the selected child
  const dues = new Map<string, { balance: number; lateFee: number; total: number; underReconciliation: boolean; gateways: string[] }>();
  let challans: FeeChallan[] = [];
  let linesByChallan: Record<string, { id: string; headName: string; lineType: string; amountPaisa: number; concessionPaisa: number; netPaisa: number }[]> = {};
  let template: { bank_name?: string; bank_account_title?: string; bank_account_no?: string } | null = null;

  if (child) {
    const { data: challansData } = await supabase
      .from('fee_challan')
      .select('id, challan_no, billing_period, issue_date, due_date, gross_paisa, concession_paisa, arrears_paisa, net_paisa, status, campus_id')
      .eq('enrolment_id', child.enrolmentId)
      .order('due_date', { ascending: false });

    challans = (challansData ?? []) as FeeChallan[];

    const { data: duesData } = await supabase
      .from('v_portal_dues')
      .select('challan_id, balance_paisa, late_fee_paisa, total_due_paisa, under_reconciliation, gateways')
      .eq('enrolment_id', child.enrolmentId);
    for (const d of duesData ?? []) {
      if (d.challan_id) dues.set(d.challan_id, { balance: Number(d.balance_paisa ?? 0), lateFee: Number(d.late_fee_paisa ?? 0), total: Number(d.total_due_paisa ?? 0), underReconciliation: Boolean(d.under_reconciliation), gateways: d.gateways ?? [] });
    }

    const challanIds = challans.map((c) => c.id);

    if (challanIds.length > 0) {
      // Fetch lines
      const { data: linesData } = await supabase
        .from('fee_challan_line')
        .select('id, challan_id, amount_paisa, concession_paisa, net_paisa, line_type, fee_head_id')
        .in('challan_id', challanIds);

      // Fetch head names
      const headIds = Array.from(new Set((linesData ?? []).map((l) => l.fee_head_id)));
      const { data: headsData } = headIds.length > 0
        ? await supabase.from('fee_head').select('id, name_en, code').in('id', headIds)
        : { data: [] };

      const headMap = new Map<string, string>();
      for (const h of headsData ?? []) {
        headMap.set(h.id, h.name_en || h.code);
      }

      for (const l of linesData ?? []) {
        if (!linesByChallan[l.challan_id]) {
          linesByChallan[l.challan_id] = [];
        }
        linesByChallan[l.challan_id]!.push({
          id: l.id,
          headName: headMap.get(l.fee_head_id) || 'Tuition / School Fee',
          lineType: l.line_type,
          amountPaisa: l.amount_paisa,
          concessionPaisa: l.concession_paisa,
          netPaisa: l.net_paisa,
        });
      }

      // Fetch bank template for child's campus
      if (challans[0]?.campus_id) {
        const { data: tmpl } = await supabase
          .from('challan_template')
          .select('bank_name, bank_account_title, bank_account_no')
          .eq('campus_id', challans[0].campus_id)
          .maybeSingle();
        template = tmpl;
      }
    }
  }

  // Outstanding = what is still owed: principal balance after payments plus accrued late fee.
  const outstandingPaisa = challans
    .filter((c) => c.status === 'unpaid' || c.status === 'part_paid')
    .reduce((sum, c) => sum + (dues.get(c.id)?.total ?? c.net_paisa ?? 0), 0);

  const formatPkr = (paisa: number) => {
    return `PKR ${(paisa / 100).toLocaleString('en-PK', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
  };

  return (
    <div className="space-y-6" data-testid="portal-fees-page">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight">Fee Dues &amp; Billing</h2>
        <p className="text-sm text-muted-foreground">FR-N04 — View fee challans, outstanding balance and payment options.</p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="portal-fees-empty">
          No enrolled child found on this account.
        </p>
      ) : (
        <>
          {/* Multi-child switcher */}
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="fees-child-selector">
              {children.map((c) => (
                <Link
                  key={c.enrolmentId}
                  href={`/portal/fees?enrolment=${c.enrolmentId}`}
                  data-testid={`fees-child-${c.studentName}`}
                  className={`rounded-full border px-3 py-1 text-sm transition-colors ${
                    c.enrolmentId === child?.enrolmentId
                      ? 'bg-primary text-primary-foreground'
                      : 'text-muted-foreground hover:bg-muted'
                  }`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {/* Outstanding Balance Banner */}
          <div
            className={`rounded-xl border p-5 transition-all ${
              outstandingPaisa > 0
                ? 'bg-rose-50/50 border-rose-200 dark:bg-rose-950/20 dark:border-rose-900'
                : 'bg-emerald-50/50 border-emerald-200 dark:bg-emerald-950/20 dark:border-emerald-900'
            }`}
          >
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
              <div>
                <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                  Current Outstanding Balance
                </span>
                <div
                  className={`text-3xl font-extrabold mt-1 ${
                    outstandingPaisa > 0 ? 'text-rose-600 dark:text-rose-400' : 'text-emerald-600 dark:text-emerald-400'
                  }`}
                  data-testid="fees-outstanding-balance"
                >
                  {formatPkr(outstandingPaisa)}
                </div>
                <p className="text-xs text-muted-foreground mt-1">
                  {outstandingPaisa > 0
                    ? 'Please clear pending challans before the due date to avoid late payment surcharges.'
                    : 'All dues for this student are currently cleared. Thank you!'}
                </p>
              </div>

              {outstandingPaisa > 0 && (
                <div className="text-xs rounded-lg border bg-card/80 p-3 shadow-sm sm:max-w-xs">
                  <span className="font-semibold text-foreground">Quick Payment Notice:</span>
                  <p className="text-muted-foreground mt-1">
                    Pay online via mobile app using 1Bill Voucher or deposit at any designated bank branch.
                  </p>
                </div>
              )}
            </div>
          </div>

          {/* Challans List */}
          <Card className="shadow-sm border-muted">
            <CardHeader className="pb-3 border-b">
              <CardTitle className="text-base font-semibold">Challan History</CardTitle>
            </CardHeader>
            <CardContent className="pt-4">
              {challans.length === 0 ? (
                <div className="py-8 text-center text-sm text-muted-foreground" data-testid="fees-no-challans">
                  No fee challans generated for this student yet.
                </div>
              ) : (
                <div className="space-y-4">
                  {challans.map((challan) => {
                    const cfg = STATUS_CONFIG[challan.status] ?? {
                      label: challan.status,
                      badgeClass: 'bg-muted text-muted-foreground',
                    };
                    const isOverdue =
                      challan.status !== 'paid' &&
                      new Date(`${challan.due_date}T23:59:59`) < new Date();

                    return (
                      <div
                        key={challan.id}
                        className="rounded-lg border p-4 hover:border-primary/40 transition-colors bg-card shadow-sm"
                        data-testid={`challan-card-${challan.challan_no}`}
                      >
                        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 border-b pb-3">
                          <div className="flex items-center gap-2 flex-wrap">
                            <span className="font-bold text-sm" data-testid={`challan-no-${challan.challan_no}`}>
                              Challan #{challan.challan_no}
                            </span>
                            <span
                              className={`px-2.5 py-0.5 rounded-full text-xs font-medium border ${cfg.badgeClass}`}
                              data-testid={`challan-status-${challan.challan_no}`}
                            >
                              {dues.get(challan.id)?.underReconciliation ? 'Payment under reconciliation' : cfg.label}
                            </span>
                            {isOverdue && (
                              <span className="px-2 py-0.5 rounded-full text-xs font-semibold bg-rose-600 text-white">
                                Overdue
                              </span>
                            )}
                          </div>

                          <div className="text-sm font-bold text-emerald-600 dark:text-emerald-400">
                            {formatPkr(challan.net_paisa)}
                          </div>
                        </div>

                        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs py-3 text-muted-foreground">
                          <div>
                            <span>Period:</span>{' '}
                            <span className="font-medium text-foreground">{challan.billing_period}</span>
                          </div>
                          <div>
                            <span>Issue Date:</span>{' '}
                            <span className="font-medium text-foreground">{challan.issue_date}</span>
                          </div>
                          <div>
                            <span>Due Date:</span>{' '}
                            <span className={`font-medium ${isOverdue ? 'text-rose-600 font-bold' : 'text-foreground'}`}>
                              {challan.due_date}
                            </span>
                          </div>
                          <div>
                            <span>Concession:</span>{' '}
                            <span className="font-medium text-foreground">
                              {challan.concession_paisa > 0 ? `-${formatPkr(challan.concession_paisa)}` : 'PKR 0'}
                            </span>
                          </div>
                        </div>

                        {challan.status !== 'paid' && dues.get(challan.id) && (
                          <div className="space-y-1 border-t py-3 text-sm" data-testid={`dues-${challan.challan_no}`}>
                            <div className="flex justify-between">
                              <span>Balance</span>
                              <span data-testid={`balance-${challan.challan_no}`}>{formatPkr(dues.get(challan.id)!.balance)}</span>
                            </div>
                            {dues.get(challan.id)!.lateFee > 0 && (
                              <div className="flex justify-between text-rose-700">
                                <span>Late fee</span>
                                <span data-testid={`late-fee-${challan.challan_no}`}>{formatPkr(dues.get(challan.id)!.lateFee)}</span>
                              </div>
                            )}
                            <div className="flex justify-between font-semibold">
                              <span>Total due</span>
                              <span data-testid={`total-due-${challan.challan_no}`}>{formatPkr(dues.get(challan.id)!.total)}</span>
                            </div>
                            <PayPanel
                              challanId={challan.id}
                              challanNo={challan.challan_no}
                              status={challan.status}
                              balancePaisa={dues.get(challan.id)!.balance}
                              underReconciliation={dues.get(challan.id)!.underReconciliation}
                              gateways={dues.get(challan.id)!.gateways}
                            />
                          </div>
                        )}

                        {/* Actions */}
                        <div className="pt-2 border-t flex items-center justify-between">
                          <div className="text-[11px] text-muted-foreground">
                            {linesByChallan[challan.id]?.length ?? 0} fee head item(s) included
                          </div>

                          <ChallanActionsClient
                            challan={{
                              id: challan.id,
                              challanNo: challan.challan_no,
                              billingPeriod: challan.billing_period,
                              issueDate: challan.issue_date,
                              dueDate: challan.due_date,
                              netPaisa: challan.net_paisa,
                              grossPaisa: challan.gross_paisa,
                              concessionPaisa: challan.concession_paisa,
                              arrearsPaisa: challan.arrears_paisa,
                              status: challan.status,
                              lines: linesByChallan[challan.id] ?? [],
                              studentName: child?.studentName ?? '',
                              sectionLabel: child?.sectionLabel ?? '',
                              bankName: template?.bank_name,
                              bankAccountTitle: template?.bank_account_title,
                              bankAccountNo: template?.bank_account_no,
                            }}
                          />
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

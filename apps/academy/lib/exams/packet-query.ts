/**
 * FR-J11. The shape fn_report_card_packet_plan() returns, and the named errors
 * the packet RPCs raise turned into something a person can read.
 */
export type PacketStatus = 'with_challan' | 'card_only' | 'withheld' | 'no_card';

export type PacketCandidate = {
  enrolment_id: string;
  student_name: string;
  gr_number: string;
  roll_no: number | null;
  report_card_id: string | null;
  challan_id: string | null;
  challan_no: string | null;
  payable_paisa: number | null;
  due_date: string | null;
  packet_id: string | null;
  assembled: boolean;
  status: PacketStatus;
};

export type PacketPlan = {
  exam_term_id: string;
  section_id: string;
  billing_period: string | null;
  total: number;
  with_challan_count: number;
  card_only_count: number;
  withheld_count: number;
  no_card_count: number;
  card_only: string[];
  candidates: PacketCandidate[];
};

export const PACKET_STATUS_LABEL: Record<PacketStatus, string> = {
  with_challan: 'Card + challan',
  card_only: 'Card only — no challan generated',
  withheld: 'Result withheld — nothing produced',
  no_card: 'No issued report card',
};

/** AC2's sentence for the batch summary. */
export function cardOnlySummary(plan: Pick<PacketPlan, 'card_only_count'>): string | null {
  if (plan.card_only_count === 0) return null;
  const n = plan.card_only_count;
  return `${n} candidate${n === 1 ? ' has' : 's have'} no challan for this cycle, so the packet is the report card alone.`;
}

export function packetError(message: string): string {
  if (message.includes('REPORT_CARD_NOT_ISSUED')) return 'Issue this candidate’s report card first; the packet is that card followed by the challan.';
  if (message.includes('ENROLMENT_NOT_FOUND')) return 'That candidate is no longer enrolled.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('SECTION_NOT_FOUND')) return 'Section not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to assemble report card packets.';
  // FR-J08's own sentences ("Result withheld — please contact the accounts office…") pass through.
  const line = message.split('\n')[0]?.trim() ?? message;
  if (/withheld/i.test(line)) return line;
  return 'Could not assemble the packet.';
}

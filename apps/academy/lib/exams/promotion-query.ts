import type { PromotionDecision } from '@/lib/validation';

/**
 * FR-J04. The shape fn_promotion_sheet() returns: the rule in force for the
 * class and every candidate's standing decision, with what the rules said
 * beside it whenever a Principal has overridden.
 */
export type PromotionRuleView = {
  min_aggregate_pct: number;
  max_failed_for_compartment: number;
  max_failed_for_promotion: number;
  source: 'default' | 'campus' | 'class';
};

export type PromotionRow = {
  decision_id: string;
  enrolment_id: string;
  student_name: string;
  gr_number: string;
  roll_no: number | null;
  decision: PromotionDecision;
  system_decision: PromotionDecision;
  aggregate_pct: number | null;
  failed_subjects: { subject_id: string; subject_name: string; pct: number | null }[];
  pending_reason: string | null;
  overridden: boolean;
  overridden_by_name: string | null;
  override_reason: string | null;
  handoff_conflict: boolean;
};

export type PromotionSheet = {
  session_id: string;
  class_id: string;
  campus_id: string | null;
  rule: PromotionRuleView;
  can_evaluate: boolean;
  can_override: boolean;
  decisions: PromotionRow[];
};

export const DECISION_LABEL: Record<PromotionDecision, string> = {
  promoted: 'Promoted',
  promoted_on_trial: 'Promoted on trial',
  compartment: 'Compartment',
  detained: 'Detained',
  pending: 'Pending',
};

export const PENDING_REASON_LABEL: Record<string, string> = {
  withheld: 'Result withheld',
  debarred: 'Debarred in a paper',
  no_result: 'No annual result yet',
  provisional: 'A term is still being marked',
};

/** The promotion batch is every decision that is not Pending (AC3). */
export function promotionBatch(rows: PromotionRow[]): PromotionRow[] {
  return rows.filter((r) => r.decision !== 'pending');
}

/** The named errors the promotion RPCs raise, turned into something a person can read. */
export function promotionError(message: string): string {
  if (message.includes('PROMOTION_BLOCKED')) {
    return 'This student is detained or awaiting a result, so they cannot be enrolled into the next class.';
  }
  if (message.includes('OVERRIDE_REASON_REQUIRED')) return 'An override needs a reason.';
  if (message.includes('OVERRIDE_TARGET_INVALID')) return 'Pending is a missing result, not a decision that can be granted.';
  if (message.includes('RULE_ORDER')) {
    return 'Failures allowed for promotion cannot exceed those allowed for a compartment.';
  }
  if (message.includes('RULE_INVALID')) return 'The promotion rule is not valid.';
  if (message.includes('SESSION_NOT_FOUND')) return 'Academic session not found.';
  if (message.includes('CLASS_NOT_FOUND')) return 'That class is not part of this school.';
  if (message.includes('DECISION_NOT_FOUND')) return 'That decision no longer exists.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete the promotion action.';
}

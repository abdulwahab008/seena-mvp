/**
 * FR-J05. The shape fn_position_sheet() returns: one term's merit list for a
 * whole class — every section of it — plus the policy that decided who is on
 * the list and whether a mark has moved under it since.
 */
export type RankPolicy = 'exclude_absentees' | 'include_all';

/**
 * FR-I16 approves per (paper, section), so a class can be half signed off. A
 * class position against half a cohort would change the day the rest landed,
 * so nothing is ranked until `ready`.
 */
export type PositionReadiness = {
  exam_term_id: string;
  class_level_id: string;
  section_count: number;
  ready_count: number;
  pending_sections: string[];
  ready: boolean;
};

export type PositionCandidate = {
  enrolment_id: string;
  student_name: string;
  gr_number: string;
  roll_no: number | null;
  section_id: string;
  section_name: string;
  total_obtained: number;
  /** FR-I11 shrinks this for an exempt candidate, so it is shown, not assumed. */
  total_max: number;
  /** Null for an unranked candidate — AC2's dash is a null, never a zero. */
  rank_in_section: number | null;
  /** AC1: the number of RANKED candidates in the section, not its strength. */
  ranked_out_of: number | null;
  rank_in_class: number | null;
  ranked_out_of_class: number | null;
  is_ranked: boolean;
  /** 'absent' or 'withheld'. Null for a ranked candidate. */
  exclusion_reason: string | null;
};

export type PositionSheet = {
  exam_term_id: string;
  exam_term_name: string;
  class_level_id: string;
  readiness: PositionReadiness;
  rank_policy: RankPolicy;
  can_compute: boolean;
  computed_at: string | null;
  /** FR-I17, class-wide: one mark in 9-C moves the class rank of 9-A. */
  is_stale: boolean;
  candidates: PositionCandidate[];
};

/** AC1's "out of" sentence, and AC2's dash where there is no position. */
export function positionDisplay(rank: number | null, outOf: number | null): string {
  return rank === null || outOf === null ? '—' : `${rank} of ${outOf}`;
}

/** Why a candidate has no position, said rather than left blank. */
export function exclusionLabel(reason: string | null): string {
  if (reason === 'withheld') return 'Withheld — debarred in this term';
  if (reason === 'absent') return 'Absent in a paper';
  return '';
}

export const RANK_POLICY_LABELS: Record<RankPolicy, string> = {
  exclude_absentees: 'Exclude absentees — a candidate absent in any paper has no position',
  include_all: 'Include everyone — an absence scores zero and still ranks',
};

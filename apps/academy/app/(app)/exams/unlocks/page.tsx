import { supabaseServer } from '@/lib/supabase/server';
import type { MarkUnlockException, MarkUnlockRequestRow } from '@/lib/exams/mark-query';
import { MARK_UNLOCK_APPROVER_ROLES, MARK_UNLOCK_REQUESTER_ROLES } from '@/lib/validation';
import { UnlockBoard } from './unlock-board';

/**
 * FR-I17. Break-glass requests, the windows they open, and AC4's exceptions
 * report.
 *
 * Requests are RAISED on the approval board, beside the locked paper the
 * controller is looking at when they realise a mark is wrong. This page is
 * where they are decided and where the record of every one of them lives.
 *
 * The role gate is the read policy's, restated so a user who cannot see any of
 * this is told why rather than shown three empty lists.
 */
export default async function MarkUnlocksPage() {
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  if (!MARK_UNLOCK_REQUESTER_ROLES.includes(role as (typeof MARK_UNLOCK_REQUESTER_ROLES)[number])) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Break-glass unlocks</h1>
        <p className="text-sm text-muted-foreground" data-testid="unlocks-forbidden">
          Reopening a signed-off mark set is the exam office&rsquo;s. A Subject Teacher cannot raise or see a
          break-glass request.
        </p>
      </div>
    );
  }

  const { data: requestRows } = await supabase
    .from('v_mark_unlock_request')
    .select(
      'id, exam_subject_id, section_id, subject_name, class_name, section_name, reason, status, requested_by, requested_by_name, requested_at, approved_by_name, approved_at, expires_at, decision_note, edit_count',
    )
    .order('requested_at', { ascending: false });
  const requests = (requestRows ?? []) as unknown as MarkUnlockRequestRow[];

  const now = Date.now();
  const pending = requests.filter((r) => r.status === 'pending');
  // "Open" is asked the same way the write path asks it — an approved request
  // whose deadline has not passed — so a lapsed window that the sweep has not
  // reached yet is not listed as if it were still live.
  const open = requests.filter(
    (r) => r.status === 'approved' && r.expires_at !== null && new Date(r.expires_at).getTime() > now,
  );
  const decided = requests.filter((r) => r.status === 'rejected');

  const { data: exceptionRows } = await supabase
    .from('v_mark_unlock_exception')
    .select(
      'exam_subject_id, exam_term_name, subject_name, class_name, unlock_count, sections, reasons, approvers, requesters, windows_with_edits, first_unlocked_at, last_unlocked_at',
    )
    .order('unlock_count', { ascending: false });
  const exceptions = (exceptionRows ?? []) as unknown as MarkUnlockException[];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Break-glass unlocks</h1>
        <p className="text-sm text-muted-foreground">
          FR-I17 &mdash; the only way past an approved mark lock. Two people, a written reason and a window that closes
          on the clock rather than when the tab does. Every mark changed inside one is recorded against the request that
          allowed it.
        </p>
      </div>

      <UnlockBoard
        currentUserId={user!.id}
        canDecide={MARK_UNLOCK_APPROVER_ROLES.includes(role as (typeof MARK_UNLOCK_APPROVER_ROLES)[number])}
        pending={pending}
        open={open}
        decided={decided}
        exceptions={exceptions}
      />
    </div>
  );
}

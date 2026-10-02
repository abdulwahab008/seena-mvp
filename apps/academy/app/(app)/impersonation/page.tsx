import { supabaseServer } from '@/lib/supabase/server';
import { isImpersonatable } from '@/lib/impersonation';
import { ImpersonationView, type ConsentRow, type SessionRow, type UserOption } from './impersonation-view';

// Matches impersonation_consent_read / impersonation_session_read. A Principal
// reads the log but neither grants consent nor impersonates — both of those
// RPCs refuse them, and the panels below are hidden accordingly.
const VIEW_ROLES = ['super_admin', 'owner', 'principal'];

export default async function ImpersonationPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).maybeSingle();
  const role = appUser?.app_role ?? 'none';
  const canView = VIEW_ROLES.includes(role);

  let users: UserOption[] = [];
  let consents: ConsentRow[] = [];
  let sessions: SessionRow[] = [];

  if (canView) {
    const [{ data: userRows }, { data: consentRows }, { data: sessionRows }] = await Promise.all([
      supabase.from('app_user').select('user_id, full_name, app_role').eq('status', 'active').order('full_name'),
      supabase
        .from('impersonation_consent')
        .select('id, granted_by, granted_at, expires_at, revoked_at, scope, target_user_id')
        .order('granted_at', { ascending: false })
        .limit(20),
      supabase
        .from('impersonation_session')
        .select(
          'id, support_user_id, target_user_id, target_role, started_at, ends_at, ended_at, end_reason, read_count, write_count, blocked_write_count',
        )
        .order('started_at', { ascending: false })
        .limit(25),
    ]);

    const nameOf = new Map((userRows ?? []).map((u) => [u.user_id, u.full_name]));
    const named = (id: string | null) => (id ? (nameOf.get(id) ?? 'Unknown user') : 'Unknown user');
    const now = Date.now();

    users = (userRows ?? [])
      .filter((u) => isImpersonatable(u.app_role))
      .map((u) => ({ id: u.user_id, name: u.full_name, role: u.app_role }));

    consents = (consentRows ?? []).map((c) => ({
      id: c.id,
      scope: c.scope,
      targetName: c.scope === 'tenant' ? 'Anyone in the school' : named(c.target_user_id),
      grantedByName: named(c.granted_by),
      grantedAt: c.granted_at,
      expiresAt: c.expires_at,
      revokedAt: c.revoked_at,
      live: c.revoked_at === null && Date.parse(c.expires_at) > now,
    }));

    sessions = (sessionRows ?? []).map((s) => ({
      id: s.id,
      engineerName: named(s.support_user_id),
      targetName: named(s.target_user_id),
      targetRole: s.target_role,
      startedAt: s.started_at,
      endsAt: s.ends_at,
      endedAt: s.ended_at,
      endReason: s.end_reason,
      readCount: s.read_count,
      writeCount: s.write_count,
      blockedWriteCount: s.blocked_write_count,
      isMine: s.support_user_id === user!.id,
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Support access</h1>
        <p className="text-sm text-muted-foreground">
          FR-A16 — platform support can see the product exactly as one of your staff sees it, but only while you say so. Consent
          lasts at most 24 hours and you can withdraw it mid-session; a session lasts at most 60 minutes; and money and results can
          never be changed from inside one.
        </p>
      </div>
      {canView ? (
        <ImpersonationView role={role} users={users} consents={consents} sessions={sessions} />
      ) : (
        <p className="text-sm text-muted-foreground" data-testid="impersonation-forbidden">
          Only an Owner, Principal or platform Super Admin can see support access records.
        </p>
      )}
    </div>
  );
}

import { siteUrl } from '@/lib/auth/recovery';
import { emailConfigured, sendEmail } from '@/lib/email/send';
import { staffInvitationEmail } from '@/lib/email/templates';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { roleLabel } from '@/lib/staff-roles';

export type InviteDelivery = { link: string; emailed: boolean; note: string | null };

// Audit BUG-01: an invitation used to be a database row and nothing else. Every invitation now
// gets a join link the inviter can always copy, and an email when the mail provider is set up.
// The caller must already have shown the user may manage this invitation.
export async function deliverInvitation(invitationId: string): Promise<InviteDelivery | null> {
  const admin = supabaseServiceRole();
  const { data: inv } = await admin
    .from('tenant_invitation')
    .select('token, email, app_role, accepted_at, tenant:tenant_id(name)')
    .eq('id', invitationId)
    .maybeSingle();
  if (!inv || inv.accepted_at) return null;

  const link = `${siteUrl()}/accept-invite/${inv.token}`;
  if (!emailConfigured()) return { link, emailed: false, note: 'Email is not set up on this server.' };

  const tenant = Array.isArray(inv.tenant) ? inv.tenant[0] : inv.tenant;
  const message = staffInvitationEmail({ url: link, schoolName: tenant?.name ?? 'your school', roleLabel: roleLabel(inv.app_role) });
  const result = await sendEmail({ to: inv.email, subject: message.subject, html: message.html, text: message.text });
  if (!result.ok) {
    console.error(`[staff-invite] email ${result.reason}: ${result.detail}`);
    return { link, emailed: false, note: 'The email could not be sent.' };
  }
  return { link, emailed: true, note: null };
}

import { supabaseServer } from '@/lib/supabase/server';
import { SiblingDiscountView, type RankRow } from './sibling-discount-view';

export default async function SiblingDiscountsPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }, { data: schemes }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id').eq('is_current', true).order('starts_on', { ascending: false }),
    supabase.from('concession_scheme').select('id, code, name_en').eq('is_active', true).order('code'),
  ]);

  const campus = campuses?.[0];
  const session = sessions?.[0];

  let ranks: RankRow[] = [];
  let canConfigure = false;

  if (campus && session) {
    const {
      data: { user },
    } = await supabase.auth.getUser();
    const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
    canConfigure = appUser?.app_role === 'super_admin' || appUser?.app_role === 'owner';

    const { data: rankRows } = await supabase
      .from('sibling_discount_scheme_rank')
      .select('sibling_rank, scheme_id, concession_scheme(name_en)')
      .order('sibling_rank');

    ranks = (rankRows ?? []).map((r) => {
      const scheme = Array.isArray(r.concession_scheme) ? r.concession_scheme[0] : r.concession_scheme;
      return { siblingRank: r.sibling_rank, schemeId: r.scheme_id, schemeName: scheme?.name_en ?? 'Unknown' };
    });
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Sibling discounts</h1>
        <p className="text-sm text-muted-foreground">
          FR-K07 — detects families by guardian CNIC and proposes a draft award per configured rank. Never auto-approved.
        </p>
      </div>
      {campus && session ? (
        <SiblingDiscountView campusId={campus.id} sessionId={session.id} ranks={ranks} schemes={schemes ?? []} canConfigure={canConfigure} />
      ) : (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      )}
    </div>
  );
}

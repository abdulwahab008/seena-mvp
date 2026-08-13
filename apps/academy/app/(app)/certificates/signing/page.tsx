import { supabaseServer } from '@/lib/supabase/server';
import { SigningIdentityManager, type CampusOption, type IdentityRow } from './signing-identity-manager';

// AC4 and signing_identity_write_owner: whose signature goes on a statutory
// document is the Owner's decision, not the Principal's. The database is
// what enforces it — create_signing_identity(), the RLS policy and the
// restrictive storage policy all refuse independently; this only decides
// whether to draw the form.
const SIGNING_ROLES = ['super_admin', 'owner'];

export default async function SigningIdentityPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const canManage = SIGNING_ROLES.includes(appUser?.app_role ?? 'none');

  let campuses: CampusOption[] = [];
  let identities: IdentityRow[] = [];

  if (canManage) {
    const [{ data: campusRows }, { data: identityRows }] = await Promise.all([
      supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
      supabase
        .from('signing_identity')
        .select(
          'id, campus_id, holder_name, designation, valid_from, valid_to, signature:signature_asset_id(width_px), stamp:stamp_asset_id(width_px), certificate_issue(count)',
        )
        .order('valid_from', { ascending: false })
        .limit(100),
    ]);

    campuses = (campusRows ?? []) as CampusOption[];
    type IdentityQueryRow = {
      id: string;
      campus_id: string;
      holder_name: string;
      designation: string;
      valid_from: string;
      valid_to: string | null;
      signature: { width_px: number } | null;
      stamp: { width_px: number } | null;
      certificate_issue: { count: number }[];
    };
    identities = ((identityRows ?? []) as unknown as IdentityQueryRow[]).map((r) => ({
      id: r.id,
      campusId: r.campus_id,
      holderName: r.holder_name,
      designation: r.designation,
      validFrom: r.valid_from,
      validTo: r.valid_to,
      signatureWidthPx: r.signature?.width_px ?? 0,
      stampWidthPx: r.stamp?.width_px ?? null,
      // AC3's evidence, on the page: a closed identity still has
      // certificates pointing at it, and they still print its signature.
      issuedCount: r.certificate_issue[0]?.count ?? 0,
    }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Certificate signing identity</h1>
        <p className="text-sm text-muted-foreground">
          FR-T09 — the signature and school stamp composited onto every certificate this campus issues, at 300 DPI, with a
          per-issue digest that a download re-checks before it hands the file over.
        </p>
      </div>

      {!canManage ? (
        <p className="text-sm text-muted-foreground" data-testid="signing-forbidden">
          Only an Owner or Super Admin can manage the certificate signing identity.
        </p>
      ) : (
        <SigningIdentityManager campuses={campuses} identities={identities} />
      )}
    </div>
  );
}

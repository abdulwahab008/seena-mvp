import { supabaseServer } from '@/lib/supabase/server';
import { TemplateDesigner, type CampusOption, type CatalogRow, type TemplateRow } from './template-designer';

// Same authoring roles as cert_template_write_admin and every RPC in
// 20260731860000_certificate_template_designer.sql; the database is what
// actually enforces it.
const AUTHOR_ROLES = ['super_admin', 'owner', 'principal'];

export default async function CertificateTemplatesPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';
  const canAuthor = AUTHOR_ROLES.includes(role);
  // Only an Owner or Super Admin may author the tenant-wide default that
  // every campus without its own falls back to (AC3).
  const canAuthorTenantDefault = role === 'super_admin' || role === 'owner';

  let templates: TemplateRow[] = [];
  let catalog: CatalogRow[] = [];
  let campuses: CampusOption[] = [];

  if (canAuthor) {
    const [{ data: templateRows }, { data: catalogRows }, { data: campusRows }] = await Promise.all([
      supabase
        .from('certificate_template')
        .select(
          'id, campus_id, certificate_type, board_code, language, version, title, body_html, page_size, status, activated_at, merge_field_whitelist, campus:campus_id(code, name)',
        )
        .order('certificate_type')
        .order('version', { ascending: false }),
      supabase
        .from('certificate_type_field_catalog')
        .select('certificate_type, field_path, required, label_en')
        .order('field_path'),
      supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    ]);
    templates = (templateRows ?? []) as unknown as TemplateRow[];
    catalog = (catalogRows ?? []) as CatalogRow[];
    campuses = campusRows ?? [];
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Certificate templates</h1>
        <p className="text-sm text-muted-foreground">
          FR-T01 — the exact wording, layout and letterhead of each certificate type, per board, campus and language. A
          template is activated only once every merge field it uses is one this system can actually resolve.
        </p>
      </div>
      {canAuthor ? (
        <TemplateDesigner
          templates={templates}
          catalog={catalog}
          campuses={campuses}
          canAuthorTenantDefault={canAuthorTenantDefault}
        />
      ) : (
        <p className="text-sm text-muted-foreground" data-testid="cert-template-forbidden">
          Only an Owner, Super Admin or Principal can design certificate templates.
        </p>
      )}
    </div>
  );
}

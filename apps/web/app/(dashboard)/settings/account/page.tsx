import { requireSession } from '@/lib/auth';
import { OrgDangerZone } from '@/components/settings/org-danger-zone';

export default async function AccountSettingsPage() {
  const { role } = await requireSession();
  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Account &amp; data</h1>
      {role === 'admin' ? (
        <OrgDangerZone />
      ) : (
        <p className="text-sm text-muted-foreground">
          Only an organization admin can export or delete organization data.
        </p>
      )}
    </div>
  );
}

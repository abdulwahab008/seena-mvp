import { supabaseServer } from '@/lib/supabase/server';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Alert } from '@/components/ui/alert';
import { NewSchoolForm } from './new-school-form';
import { SchoolList } from './school-list';

export default async function PlatformPage() {
  const supabase = await supabaseServer();
  const { data: schools, error } = await supabase.rpc('platform_list_tenants');

  return (
    <>
      <PageHeader title="Schools" description="Every school on Seena. Create a school, resend its owner's invitation, or suspend it." />
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        {error ? (
          <Alert variant="destructive" title="Could not load schools">
            Reload the page. If it keeps failing, check the database logs.
          </Alert>
        ) : (
          <SchoolList schools={schools ?? []} />
        )}
        <Card className="h-fit">
          <CardHeader>
            <CardTitle>New school</CardTitle>
          </CardHeader>
          <CardContent>
            <NewSchoolForm />
          </CardContent>
        </Card>
      </div>
    </>
  );
}

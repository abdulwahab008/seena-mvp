import { supabaseServer } from '@/lib/supabase/server';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Alert } from '@/components/ui/alert';
import { NewSchoolForm } from './new-school-form';
import { SchoolList } from './school-list';
import { RegistrationRequests } from './registration-requests';

export default async function PlatformPage() {
  const supabase = await supabaseServer();
  const [{ data: schools, error }, { data: requests }] = await Promise.all([
    supabase.rpc('platform_list_tenants'),
    supabase
      .from('school_registration_request')
      .select('id, school_name, contact_name, phone, email, city, students, message, status, created_at')
      .in('status', ['new', 'contacted'])
      .order('created_at', { ascending: false })
      .limit(100),
  ]);

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
      <section className="mt-8 space-y-3">
        <h2 className="text-lg font-semibold">Join requests</h2>
        <RegistrationRequests requests={requests ?? []} />
      </section>
    </>
  );
}

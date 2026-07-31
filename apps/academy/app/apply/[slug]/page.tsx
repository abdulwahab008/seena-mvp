import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { supabaseServer } from '@/lib/supabase/server';
import { PublicEnquiryForm } from './public-enquiry-form';

type ClassLevelOption = { code: string; name_en: string; name_ur: string | null };

export default async function PublicApplyPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_public_school_info', { p_tenant_slug: slug });

  if (error || !data) {
    return (
      <div className="flex min-h-screen items-center justify-center p-4">
        <Card className="w-full max-w-sm" data-testid="school-not-found">
          <CardHeader>
            <CardTitle>School not found</CardTitle>
            <CardDescription>This admissions link is not valid. Please check the URL your school gave you.</CardDescription>
          </CardHeader>
        </Card>
      </div>
    );
  }

  const info = data as { tenant_name: string; class_levels: ClassLevelOption[] };

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-lg" data-testid="public-apply-card">
        <CardHeader>
          <CardTitle>Apply to {info.tenant_name}</CardTitle>
          <CardDescription>Tell us about your child and we&apos;ll be in touch.</CardDescription>
        </CardHeader>
        <CardContent>
          <PublicEnquiryForm slug={slug} classLevels={info.class_levels} />
        </CardContent>
      </Card>
    </div>
  );
}

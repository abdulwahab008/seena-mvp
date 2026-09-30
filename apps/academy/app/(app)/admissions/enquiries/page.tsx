import Link from 'next/link';
import { Zap } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { supabaseServer } from '@/lib/supabase/server';
import { CreateEnquiryForm } from './create-enquiry-form';
import { EnquiryList } from './enquiry-list';
import { RealtimeEnquiryRefresher } from './realtime-refresher';

export default async function EnquiriesPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: sessions }, { data: classLevels }, { data: enquiries }] = await Promise.all([
    supabase.from('campus').select('id, code, name').eq('status', 'active').order('code'),
    supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, code, name_en').eq('is_active', true).order('ordinal'),
    supabase
      .from('admission_enquiry')
      .select('id, enquiry_no, child_name, phone_e164, source, status')
      .order('created_at', { ascending: false }),
  ]);

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Admissions enquiries</h1>
          <p className="text-sm text-muted-foreground">FR-B01 — capture every walk-in, phone, web and referral enquiry.</p>
        </div>
        <Button asChild size="sm" className="gap-1.5 bg-indigo-600 hover:bg-indigo-700 text-white shadow-sm" data-testid="goto-walkin-desk-button">
          <Link href="/admissions/walk-in">
            <Zap className="h-4 w-4" />
            <span>Go to Walk-in Desk</span>
          </Link>
        </Button>
      </div>
      <RealtimeEnquiryRefresher />
      <CreateEnquiryForm campuses={campuses ?? []} sessions={sessions ?? []} classLevels={classLevels ?? []} />
      <EnquiryList enquiries={enquiries ?? []} />
    </div>
  );
}

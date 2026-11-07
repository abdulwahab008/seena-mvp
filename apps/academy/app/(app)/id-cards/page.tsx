import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { ID_CARD_ROLES } from '@/lib/id-cards/html';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { IdCardForm } from './id-card-form';

export const dynamic = 'force-dynamic';

export default async function IdCardsPage() {
  const actor = await getCurrentActor();
  if (!actor || !ID_CARD_ROLES.includes(actor.role)) notFound();

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  const { data: sections } = campus
    ? await supabase
        .from('class_section')
        .select('id, name, class_level:class_level_id(name_en, ordinal)')
        .eq('campus_id', campus.id)
        .eq('is_active', true)
    : { data: [] };

  const options = (sections ?? [])
    .map((s) => ({ id: s.id, label: `${one(s.class_level)?.name_en ?? ''} ${s.name}`.trim(), sort: one(s.class_level)?.ordinal ?? 0 }))
    .sort((a, b) => a.sort - b.sort || a.label.localeCompare(b.label));

  return (
    <>
      <PageHeader title="ID cards" description="Print identity cards for students or staff, ten to an A4 sheet, with the school logo and a barcode." />
      {campus ? (
        <Card className="max-w-xl">
          <CardContent className="p-6">
            <IdCardForm campusId={campus.id} sections={options.map(({ id, label }) => ({ id, label }))} />
          </CardContent>
        </Card>
      ) : (
        <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />
      )}
    </>
  );
}

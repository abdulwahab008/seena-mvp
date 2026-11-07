import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { DownloadList } from './download-list';
import { UploadForm } from './upload-form';

export const dynamic = 'force-dynamic';

const DOWNLOAD_ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department', 'class_teacher', 'subject_teacher', 'exam_controller', 'admissions_officer'];

export default async function DownloadsPage() {
  const actor = await getCurrentActor();
  if (!actor || !DOWNLOAD_ROLES.includes(actor.role)) notFound();

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: items }, { data: sections }] = await Promise.all([
    supabase
      .from('download_item')
      .select('id, category, title, original_filename, size_bytes, created_at, uploaded_by, class_level:class_level_id(name_en), section:section_id(name)')
      .eq('campus_id', campus.id)
      .order('created_at', { ascending: false })
      .limit(300),
    supabase.from('class_section').select('id, name, class_level_id, class_level:class_level_id(name_en, ordinal)').eq('campus_id', campus.id).eq('is_active', true),
  ]);

  const classes = [...new Map((sections ?? []).map((s) => [s.class_level_id, { id: s.class_level_id, name: one(s.class_level)?.name_en ?? '', ordinal: one(s.class_level)?.ordinal ?? 0 }])).values()].sort((a, b) => a.ordinal - b.ordinal);
  const leader = ['super_admin', 'owner', 'principal', 'vice_principal'].includes(actor.role);

  return (
    <>
      <PageHeader title="Download centre" description="Share syllabus, study material and other files with a whole campus, one class or one section. Parents see them in their portal." />
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <DownloadList
          items={(items ?? []).map((d) => ({
            id: d.id,
            category: d.category,
            title: d.title,
            fileName: d.original_filename,
            sizeBytes: d.size_bytes,
            createdAt: d.created_at,
            audience: [one(d.class_level)?.name_en, one(d.section)?.name].filter(Boolean).join(' ') || 'Whole campus',
            canDelete: leader || d.uploaded_by === actor.userId,
          }))}
        />
        <UploadForm
          campusId={campus.id}
          classes={classes.map(({ id, name }) => ({ id, name }))}
          sections={(sections ?? []).map((s) => ({ id: s.id, name: s.name, classLevelId: s.class_level_id }))}
        />
      </div>
    </>
  );
}

import { libraryViewer } from '@/lib/library-session';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CoverUpload, TitleForm } from './title-forms';
import { ReserveSelfButton } from '../reservations/reservation-forms';

type SearchParams = { q?: string; edit?: string };

export default async function LibraryTitlesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const { supabase, isStaff } = await libraryViewer();
  const q = (sp.q ?? '').trim();

  const [{ data: found }, { data: subjects }] = await Promise.all([
    supabase.rpc('search_library_titles', { p_query: q, p_limit: 50 }),
    supabase.from('subject').select('id, name_en').eq('is_active', true).order('name_en'),
  ]);
  const titles = found ?? [];
  const subjectOptions = (subjects ?? []).map((s) => ({ id: s.id, name: s.name_en }));
  // Availability comes from a security_invoker view, so it only ever counts the caller's own campuses.
  const { data: stock } = titles.length ? await supabase.from('v_title_availability').select('title_id, available_copies, total_copies').in('title_id', titles.map((t) => t.id)) : { data: [] };
  const availability = new Map<string, { available: number; total: number }>();
  for (const s of stock ?? []) {
    const cur = availability.get(s.title_id!) ?? { available: 0, total: 0 };
    availability.set(s.title_id!, { available: cur.available + (s.available_copies ?? 0), total: cur.total + (s.total_copies ?? 0) });
  }

  let editing: { id: string; row: Awaited<ReturnType<typeof loadTitle>> } | null = null;
  if (isStaff && sp.edit) editing = { id: sp.edit, row: await loadTitle(supabase, sp.edit) };

  return (
    <div className="space-y-6">
      <PageHeader title="Library catalogue" description="FR-O01. Each work is catalogued once against its ISBN; every physical copy shares this record. Locally printed books without an ISBN are fine." />

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Search title, Urdu title or ISBN</span>
          <input type="search" name="q" defaultValue={q} dir="auto" placeholder="معاشرتی علوم" className="h-9 w-72 rounded-md border bg-background px-2" data-testid="title-search" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Search
        </button>
      </form>

      {isStaff && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{editing?.row ? 'Edit title' : 'Catalogue a new title'}</CardTitle>
          </CardHeader>
          <CardContent>
            <TitleForm
              key={editing?.id ?? 'new'}
              subjects={subjectOptions}
              titleId={editing?.row ? editing.id : undefined}
              initial={
                editing?.row
                  ? {
                      title: editing.row.title, titleUr: editing.row.title_ur ?? '', rawIsbn: editing.row.raw_isbn ?? '', author: editing.row.author ?? '',
                      publisher: editing.row.publisher ?? '', edition: editing.row.edition ?? '', language: editing.row.language as 'en',
                      dewey: editing.row.dewey ?? '', subjectId: editing.row.subject_id ?? '',
                    }
                  : undefined
              }
            />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{q ? `Results for "${q}"` : 'Catalogue'} ({titles.length})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="title-list">
          {titles.length === 0 && <p className="text-muted-foreground">No titles found.</p>}
          {titles.map((t) => (
            <div key={t.id} className="flex flex-wrap items-start justify-between gap-3 border-b pb-3" data-testid="title-row">
              <div className="flex gap-3">
                {t.cover_path ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={`/api/library-covers/${t.id}`} alt={`Cover of ${t.title}`} width={48} height={64} className="h-16 w-12 rounded border object-cover" />
                ) : (
                  <div className="flex h-16 w-12 items-center justify-center rounded border text-xs text-muted-foreground">No cover</div>
                )}
                <div className="space-y-0.5">
                  <p className="font-medium">{t.title}</p>
                  {t.title_ur && (
                    <p dir="rtl" className="text-muted-foreground">
                      {t.title_ur}
                    </p>
                  )}
                  <p className="text-xs text-muted-foreground">
                    {[t.author, t.isbn13 ? `ISBN ${t.isbn13}` : 'No ISBN', t.language].filter(Boolean).join(' · ')}
                  </p>
                  <p className="text-xs" data-testid="title-stock">
                    {availability.has(t.id) ? `${availability.get(t.id)!.available} of ${availability.get(t.id)!.total} available` : 'No copies registered'}
                  </p>
                  {!isStaff && availability.get(t.id) && availability.get(t.id)!.total > 0 && availability.get(t.id)!.available === 0 && <ReserveSelfButton titleId={t.id} />}
                </div>
              </div>
              {isStaff && (
                <div className="flex flex-col items-end gap-2">
                  <a className="text-xs underline" href={`/library/copies?title=${t.id}`}>
                    Copies
                  </a>
                  <a className="text-xs underline" href={`/library/titles?edit=${t.id}`}>
                    Edit
                  </a>
                  <CoverUpload titleId={t.id} />
                </div>
              )}
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

async function loadTitle(supabase: Awaited<ReturnType<typeof libraryViewer>>['supabase'], id: string) {
  const { data } = await supabase.from('library_title').select('title, title_ur, raw_isbn, author, publisher, edition, language, dewey, subject_id').eq('id', id).maybeSingle();
  return data;
}

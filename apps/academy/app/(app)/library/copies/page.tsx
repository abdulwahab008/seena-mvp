import { libraryViewer } from '@/lib/library-session';
import { formatPkrCompact } from '@/lib/format-money';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CopyStatusButtons, ImportCopiesForm, RegisterCopyForm } from './copy-forms';

type SearchParams = { q?: string; title?: string };

const STATUS_LABEL: Record<string, string> = { available: 'Available', issued: 'Issued', reserved_hold: 'Held for reservation', in_repair: 'In repair', lost: 'Lost', written_off: 'Written off' };

export default async function LibraryCopiesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const { supabase, isStaff } = await libraryViewer();
  const q = (sp.q ?? '').trim();

  const [{ data: found }, { data: campusRows }] = await Promise.all([
    q ? supabase.rpc('search_library_titles', { p_query: q, p_limit: 10 }) : Promise.resolve({ data: [] as { id: string; title: string; title_ur: string | null }[] }),
    supabase.from('campus').select('id, name').eq('status', 'active').order('code'),
  ]);
  const campuses = (campusRows ?? []).map((c) => ({ id: c.id, name: c.name }));

  let title: { id: string; title: string; title_ur: string | null; isbn13: string | null } | null = null;
  let copies: { id: string; accession_no: string; barcode: string; status: string; shelf: string | null; purchase_cost: number | null; campus: string }[] = [];
  let availability: { campus: string; available: number; total: number }[] = [];
  if (sp.title) {
    const { data: t } = await supabase.from('library_title').select('id, title, title_ur, isbn13').eq('id', sp.title).maybeSingle();
    title = t;
    if (t) {
      const [{ data: c }, { data: a }] = await Promise.all([
        supabase.from('library_copy').select('id, accession_no, barcode, status, shelf, purchase_cost, campus:campus_id(name)').eq('title_id', t.id).order('accession_no'),
        supabase.from('v_title_availability').select('available_copies, total_copies, campus_id').eq('title_id', t.id),
      ]);
      const name = (id: string) => campuses.find((x) => x.id === id)?.name ?? 'Campus';
      copies = (c ?? []).map((r) => ({ id: r.id, accession_no: r.accession_no, barcode: r.barcode, status: r.status, shelf: r.shelf, purchase_cost: r.purchase_cost, campus: (Array.isArray(r.campus) ? r.campus[0]?.name : r.campus?.name) ?? '' }));
      availability = (a ?? []).map((r) => ({ campus: name(r.campus_id!), available: r.available_copies ?? 0, total: r.total_copies ?? 0 }));
    }
  }

  return (
    <div className="space-y-6">
      <PageHeader title="Copies and accession register" description="FR-O02. Every physical copy has its own accession number and barcode. Accession numbers are never reused, even after a write-off." />

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Find a title</span>
          <input type="search" name="q" defaultValue={q} dir="auto" className="h-9 w-72 rounded-md border bg-background px-2" data-testid="copy-title-search" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Search
        </button>
      </form>
      {q && (
        <ul className="space-y-1 text-sm" data-testid="copy-title-results">
          {(found ?? []).map((t) => (
            <li key={t.id}>
              <a className="underline" href={`/library/copies?title=${t.id}`}>
                {t.title}
              </a>
              {t.title_ur && <span dir="rtl" className="ml-2 text-muted-foreground">{t.title_ur}</span>}
            </li>
          ))}
          {(found ?? []).length === 0 && <li className="text-muted-foreground">No titles found.</li>}
        </ul>
      )}

      {title && (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">
                {title.title} {title.isbn13 ? `(ISBN ${title.isbn13})` : ''}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <div className="flex flex-wrap gap-2" data-testid="availability">
                {availability.length === 0 && <span className="text-muted-foreground">No copies registered at your campus yet.</span>}
                {availability.map((a) => (
                  <Badge key={a.campus} variant="outline">
                    {a.campus}: {a.available} of {a.total} available
                  </Badge>
                ))}
              </div>
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm" data-testid="copy-table">
                  <thead className="text-muted-foreground">
                    <tr>
                      <th className="py-1 pr-3">Accession</th>
                      <th className="pr-3">Barcode</th>
                      <th className="pr-3">Campus</th>
                      <th className="pr-3">Shelf</th>
                      <th className="pr-3">Cost</th>
                      <th className="pr-3">Status</th>
                      {isStaff && <th />}
                    </tr>
                  </thead>
                  <tbody>
                    {copies.map((c) => (
                      <tr key={c.id} className="border-t" data-testid="copy-row">
                        <td className="py-1 pr-3 font-mono">{c.accession_no}</td>
                        <td className="pr-3 font-mono">{c.barcode}</td>
                        <td className="pr-3">{c.campus}</td>
                        <td className="pr-3">{c.shelf ?? ''}</td>
                        <td className="pr-3">{c.purchase_cost != null ? formatPkrCompact(c.purchase_cost) : ''}</td>
                        <td className="pr-3">
                          <Badge variant={c.status === 'available' ? 'success' : 'outline'}>{STATUS_LABEL[c.status] ?? c.status}</Badge>
                        </td>
                        {isStaff && (
                          <td>
                            <CopyStatusButtons copyId={c.id} status={c.status} />
                          </td>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>
          {isStaff && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Register a copy</CardTitle>
              </CardHeader>
              <CardContent>
                <RegisterCopyForm titleId={title.id} campuses={campuses} />
              </CardContent>
            </Card>
          )}
        </>
      )}

      {isStaff && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Import copies from CSV</CardTitle>
          </CardHeader>
          <CardContent>
            <ImportCopiesForm campuses={campuses} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

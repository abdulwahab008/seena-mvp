import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { LibraryEntryForm, RemarkSheet, RemarksRequiredToggle, type SheetRow } from './remark-sheet';

type SearchParams = { section?: string; term?: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function RemarksPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  const { data: sections } = await supabase
    .from('class_section')
    .select('id, name, class_level(name_en)')
    .eq('is_active', true)
    .order('name');
  // A class teacher is offered only their own section(s); leadership (who teach none) sees every section.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: mine } = await supabase.from('section_class_teacher').select('section_id').eq('staff_id', user!.id);
  const ownIds = new Set((mine ?? []).map((m) => m.section_id));
  const sectionOptions = (sections ?? [])
    .filter((s) => ownIds.size === 0 || ownIds.has(s.id))
    .map((s) => ({ id: s.id, label: `${one(s.class_level)?.name_en ?? ''} ${s.name}`.trim() }));
  const { data: terms } = await supabase.from('exam_term').select('id, name, sequence').order('sequence');
  const sectionId = sectionOptions.find((s) => s.id === sp.section)?.id ?? sectionOptions[0]?.id;
  const termId = terms?.find((t) => t.id === sp.term)?.id ?? terms?.[0]?.id;

  const [{ data: sheet }, { data: library }, { data: setting }] = await Promise.all([
    sectionId && termId ? supabase.rpc('section_remark_sheet', { p_section_id: sectionId, p_exam_term_id: termId }) : Promise.resolve({ data: [] }),
    supabase.from('remark_library').select('id, category, text_en, text_ur').order('category').order('text_en'),
    campusId ? supabase.from('campus_setting').select('value').eq('campus_id', campusId).eq('key', 'remarks_required').maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const rows: SheetRow[] = (sheet ?? []).map((r) => ({
    enrolmentId: r.enrolment_id, grNumber: r.gr_number, name: r.name_en, nameUr: r.name_ur, rollNo: r.roll_no, text: r.remark_text ?? '', libraryId: r.library_id,
  }));
  const missing = rows.filter((r) => r.text === '');
  const required = setting?.value === true;

  const select = (name: string, value: string | undefined, options: { id: string; label: string }[]) => (
    <label className="space-y-1">
      <span className="block text-muted-foreground">{name}</span>
      <select name={name.toLowerCase()} defaultValue={value} className="h-9 rounded-md border bg-background px-2">
        {options.map((o) => (
          <option key={o.id} value={o.id}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Class teacher remarks</h1>
        <p className="text-sm text-muted-foreground">
          FR-J10 — one short remark (up to 250 characters, English or Urdu) per student per term. Pick from the library, type your own, or apply one remark to several students. It prints in the report card&apos;s remark box.
        </p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        {select('Section', sectionId, sectionOptions)}
        {select('Term', termId, (terms ?? []).map((t) => ({ id: t.id, label: t.name })))}
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>

      {campusId && <RemarksRequiredToggle campusId={campusId} required={required} />}

      {sectionId && termId ? (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              {rows.length} students, <span data-testid="missing-count">{missing.length}</span> without a remark
              {required && missing.length > 0 ? ` (${missing.map((m) => m.grNumber).join(', ')})` : ''}
            </CardTitle>
          </CardHeader>
          <CardContent>
            {campusId && (
              <RemarkSheet
                rows={rows}
                examTermId={termId}
                campusId={campusId}
                options={(library ?? []).map((l) => ({ id: l.id, category: l.category, textEn: l.text_en, textUr: l.text_ur }))}
              />
            )}
          </CardContent>
        </Card>
      ) : (
        <p className="text-sm text-muted-foreground">There is no section and exam term to write remarks for yet.</p>
      )}

      {campusId && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Saved library</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <LibraryEntryForm campusId={campusId} />
            <ul className="space-y-1 text-sm text-muted-foreground" data-testid="library-list">
              {(library ?? []).map((l) => (
                <li key={l.id}>
                  [{l.category}] {l.text_en}
                  {l.text_ur ? ` · ${l.text_ur}` : ''}
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

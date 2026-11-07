import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@/lib/database.types';

type Option = { id: string; label: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

/** The active sections and exam terms a results screen picks from, and which are chosen. */
export async function loadTermSection(supabase: SupabaseClient<Database>, sp: { section?: string; term?: string }) {
  const [{ data: sections }, { data: terms }] = await Promise.all([
    supabase.from('class_section').select('id, name, class_level(name_en, ordinal)').eq('is_active', true),
    supabase.from('exam_term').select('id, name, sequence').order('sequence'),
  ]);
  const sectionOptions: Option[] = (sections ?? [])
    .map((s) => ({ s, level: one(s.class_level) }))
    .sort((a, b) => (a.level?.ordinal ?? 0) - (b.level?.ordinal ?? 0) || a.s.name.localeCompare(b.s.name))
    .map(({ s, level }) => ({ id: s.id, label: `${level?.name_en ?? ''} ${s.name}`.trim() }));
  const termOptions: Option[] = (terms ?? []).map((t) => ({ id: t.id, label: t.name }));
  return {
    sectionOptions,
    termOptions,
    sectionId: sectionOptions.find((s) => s.id === sp.section)?.id ?? sectionOptions[0]?.id,
    termId: termOptions.find((t) => t.id === sp.term)?.id ?? termOptions[0]?.id,
  };
}

export function TermSectionForm({
  sectionOptions,
  termOptions,
  sectionId,
  termId,
  hidden = {},
  withSection = true,
}: {
  sectionOptions: Option[];
  termOptions: Option[];
  sectionId?: string;
  termId?: string;
  hidden?: Record<string, string>;
  withSection?: boolean;
}) {
  const pick = (label: string, name: string, value: string | undefined, options: Option[]) => (
    <label className="space-y-1">
      <span className="block text-muted-foreground">{label}</span>
      <select name={name} defaultValue={value} className="h-9 rounded-md border bg-background px-2">
        {options.map((o) => (
          <option key={o.id} value={o.id}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
  return (
    <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
      {Object.entries(hidden).map(([k, v]) => (
        <input key={k} type="hidden" name={k} value={v} />
      ))}
      {withSection && pick('Section', 'section', sectionId, sectionOptions)}
      {pick('Term', 'term', termId, termOptions)}
      <button type="submit" className="h-9 rounded-md border px-3">
        Show
      </button>
    </form>
  );
}

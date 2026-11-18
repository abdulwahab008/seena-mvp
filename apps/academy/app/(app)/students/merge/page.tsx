import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { MergeForm } from './merge-form';

type Candidate = { gr: string; name: string; father: string | null; dob: string };

// Same name, father's name and date of birth is almost always one child entered twice.
async function likelyDuplicates(): Promise<[Candidate, Candidate][]> {
  const supabase = await supabaseServer();
  // PostgREST returns at most 1000 rows per request, so read the roster in pages.
  const rows: { gr_number: string | null; name_en: string; father_name_en: string | null; dob: string }[] = [];
  for (let from = 0; ; from += 1000) {
    const { data } = await supabase
      .from('student')
      .select('gr_number, name_en, father_name_en, dob')
      .is('deleted_at', null)
      .order('id')
      .range(from, from + 999);
    rows.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  const groups = new Map<string, Candidate[]>();
  for (const s of rows) {
    if (!s.gr_number) continue;
    const key = [s.name_en, s.father_name_en ?? '', s.dob].map((v) => v.trim().toLowerCase()).join('|');
    const list = groups.get(key) ?? [];
    list.push({ gr: s.gr_number, name: s.name_en, father: s.father_name_en, dob: s.dob });
    groups.set(key, list);
  }
  const pairs: [Candidate, Candidate][] = [];
  for (const list of groups.values()) {
    if (list.length < 2) continue;
    list.sort((a, b) => a.gr.localeCompare(b.gr, 'en', { numeric: true }));
    for (const dup of list.slice(1)) pairs.push([list[0]!, dup]);
  }
  return pairs.slice(0, 50);
}

export default async function MergeStudentsPage({ searchParams }: { searchParams: Promise<{ keep?: string; remove?: string }> }) {
  const [{ keep, remove }, pairs] = await Promise.all([searchParams, likelyDuplicates()]);
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Merge duplicate students</h1>
        <p className="text-sm text-muted-foreground">
          When the same child was entered twice, move everything from the duplicate onto the record you keep: guardians, fees, attendance, results and the rest. Check the preview first. The duplicate goes to the recycle bin. If both records have something that can exist only once, such as an enrolment in the same session, nothing moves until you remove one.
        </p>
      </div>
      <MergeForm key={`${keep ?? ''}:${remove ?? ''}`} initialKeep={keep ?? ''} initialRemove={remove ?? ''} />
      {pairs.length > 0 && (
        <section className="space-y-2" data-testid="likely-duplicates">
          <h2 className="font-medium">Likely duplicates</h2>
          <p className="text-sm text-muted-foreground">Same name, father&apos;s name and date of birth. Choose one to fill the form, then preview.</p>
          <ul className="divide-y rounded-md border text-sm">
            {pairs.map(([a, b]) => (
              <li key={`${a.gr}:${b.gr}`} className="flex items-center justify-between gap-3 px-3 py-2">
                <span>
                  {a.name} · {a.father ?? 'no father name'} · GR {a.gr} and {b.gr}
                </span>
                <Link href={`?keep=${encodeURIComponent(a.gr)}&remove=${encodeURIComponent(b.gr)}`} className="shrink-0 underline">
                  Use these
                </Link>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

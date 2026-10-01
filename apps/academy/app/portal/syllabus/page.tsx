import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t } from '@/lib/i18n/messages';
import { pickTitle } from '@/lib/syllabus-title';

type SearchParams = { child?: string };

export default async function PortalSyllabusPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const lang = await getLang();
  const supabase = await supabaseServer();

  const [{ data: enrolments }, { data: visibility }] = await Promise.all([
    supabase.from('enrolment').select('student_id, student:student_id(name_en)').eq('status', 'active'),
    supabase.rpc('my_children_syllabus_visibility'),
  ]);
  const children = (enrolments ?? []).map((e) => {
    const s = Array.isArray(e.student) ? e.student[0] : e.student;
    return { id: e.student_id, name: s?.name_en ?? '' };
  });
  const child = children.find((c) => c.id === sp.child) ?? children[0];
  const shared = (visibility ?? []).find((v) => v.student_id === child?.id)?.enabled ?? false;

  // Only the view: it carries no periods, teacher or variance column.
  const { data: rows } =
    child && shared
      ? await supabase
          .from('v_parent_syllabus_coverage')
          .select('subject_id, subject_name_en, subject_name_ur, unit_sequence, title, title_ur, status, completed_on')
          .eq('student_id', child.id)
          .order('subject_name_en')
          .order('unit_sequence')
      : { data: [] };
  const subjects = [...new Map((rows ?? []).map((r) => [r.subject_id, { id: r.subject_id, en: r.subject_name_en, ur: r.subject_name_ur }])).values()];

  return (
    <div className="space-y-6">
      <h2 className="text-2xl font-semibold">{t(lang, 'syllabus.title')}</h2>

      {children.length > 1 && (
        <div className="flex flex-wrap gap-2" data-testid="syllabus-child-selector">
          {children.map((c) => (
            <Link key={c.id} href={`/portal/syllabus?child=${c.id}`} className={`rounded-full border px-3 py-1 text-sm ${c.id === child?.id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}>
              {c.name}
            </Link>
          ))}
        </div>
      )}

      {!child ? (
        <p className="text-sm text-muted-foreground">{t(lang, 'syllabus.empty')}</p>
      ) : !shared ? (
        <p className="rounded-md border p-4 text-sm" data-testid="syllabus-not-shared">
          {t(lang, 'syllabus.notShared')}
        </p>
      ) : subjects.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t(lang, 'syllabus.empty')}</p>
      ) : (
        subjects.map((s) => {
          const units = (rows ?? []).filter((r) => r.subject_id === s.id);
          return (
            <section key={s.id} className="space-y-2" data-testid="syllabus-subject">
              <h3 className="text-lg font-medium">{pickTitle(lang, s.en ?? '', s.ur)}</h3>
              <ul className="divide-y rounded-md border text-sm">
                {units.map((u) => (
                  <li key={u.unit_sequence} className="flex items-center justify-between gap-3 px-3 py-2" data-testid="syllabus-unit">
                    <span>
                      {u.unit_sequence}. {pickTitle(lang, u.title ?? '', u.title_ur)}
                    </span>
                    <span className={u.status === 'covered' ? 'text-success' : 'text-muted-foreground'} data-status={u.status}>
                      {u.status === 'covered' ? t(lang, 'syllabus.coveredOn', { date: u.completed_on ?? '' }) : t(lang, 'syllabus.pending')}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          );
        })
      )}
    </div>
  );
}

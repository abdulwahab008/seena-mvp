import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';

/**
 * FR-I04. The published datesheet for a child: only the papers that child sits,
 * the current version, and (when it has been revised) a banner with the changed
 * papers highlighted. Earlier versions stay retrievable so a parent holding an
 * older screenshot can see what was published when. A datesheet still in draft
 * is not listed: fn_portal_datesheet() answers has_datesheet = false.
 */
type SearchParams = { enrolment?: string; datesheet?: string; version?: string };

type PortalRow = {
  subject_name_en: string;
  subject_name_ur: string | null;
  start_at: string;
  end_at: string;
  hall_name: string | null;
  change_kind: string;
  previous_start_at: string | null;
  changed: boolean;
};
type PortalDatesheet = {
  has_datesheet: boolean;
  datesheet_id?: string;
  version_id?: string;
  title?: string;
  version_no?: number;
  published_at?: string;
  is_latest?: boolean;
  revised?: boolean;
  note?: string | null;
  versions?: { id: string; version_no: number; status: string; published_at: string }[];
  datesheets?: { id: string; title: string }[];
  rows?: PortalRow[];
};

const TZ = 'Asia/Karachi';
const fmtDate = (iso: string) => new Date(iso).toLocaleDateString('en-GB', { timeZone: TZ, weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
const fmtTime = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' });

export default async function PortalDatesheetPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');
  const children = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return { enrolmentId: e.id, studentName: student.name_en, sectionLabel: `${level?.name_en ?? ''} · ${section.name}` };
    })
    .filter((c): c is { enrolmentId: string; studentName: string; sectionLabel: string } => !!c);
  const child = children.find((c) => c.enrolmentId === params.enrolment) ?? children[0];

  const { data } = child
    ? await supabase.rpc('fn_portal_datesheet', {
        p_enrolment_id: child.enrolmentId,
        p_datesheet_id: params.datesheet || undefined,
        p_version_no: params.version ? Number(params.version) : undefined,
      })
    : { data: null };
  const sheet = data as unknown as PortalDatesheet | null;
  const base = child ? `/portal/datesheet?enrolment=${child.enrolmentId}` : '/portal/datesheet';

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Datesheet</h2>
        <p className="text-sm text-muted-foreground">FR-I04 — when each of your child&apos;s papers is held.</p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground">No enrolled child found on this account.</p>
      ) : (
        <>
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="datesheet-child-selector">
              {children.map((c) => (
                <Link
                  key={c.enrolmentId}
                  href={`/portal/datesheet?enrolment=${c.enrolmentId}`}
                  className={`rounded-full border px-3 py-1 text-sm ${c.enrolmentId === child?.enrolmentId ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {!sheet?.has_datesheet ? (
            <p className="text-sm text-muted-foreground" data-testid="portal-datesheet-empty">
              No datesheet has been published yet.
            </p>
          ) : (
            <>
              {(sheet.datesheets?.length ?? 0) > 1 && (
                <div className="flex flex-wrap gap-2">
                  {sheet.datesheets!.map((d) => (
                    <Link key={d.id} href={`${base}&datesheet=${d.id}`} className={`rounded-full border px-3 py-1 text-sm ${d.id === sheet.datesheet_id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}>
                      {d.title}
                    </Link>
                  ))}
                </div>
              )}

              <div className="flex flex-wrap items-center justify-between gap-2">
                <h3 className="text-lg font-medium" data-testid="portal-datesheet-title">
                  {sheet.title} · version {sheet.version_no}
                </h3>
                <a className="text-sm underline" href={`/api/datesheets/${sheet.version_id}/pdf`} data-testid="portal-datesheet-pdf">
                  Download PDF
                </a>
              </div>

              {sheet.revised && sheet.is_latest && (
                <p className="rounded bg-amber-50 p-2 text-sm font-medium text-amber-900" role="status" data-testid="datesheet-revised-banner">
                  Revised — this datesheet was updated on {fmtDate(sheet.published_at!)}.{sheet.note ? ` ${sheet.note}` : ''} Changed papers are highlighted.
                </p>
              )}
              {!sheet.is_latest && (
                <p className="rounded bg-muted p-2 text-sm" role="status" data-testid="datesheet-old-version">
                  You are viewing an earlier version, published on {fmtDate(sheet.published_at!)}. <Link className="underline" href={`${base}&datesheet=${sheet.datesheet_id}`}>See the current datesheet</Link>.
                </p>
              )}

              <table className="w-full text-sm" data-testid="portal-datesheet-table">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="py-1">Date</th>
                    <th className="py-1">Time</th>
                    <th className="py-1">Subject</th>
                    <th className="py-1">Hall</th>
                  </tr>
                </thead>
                <tbody>
                  {(sheet.rows ?? []).map((r) => (
                    <tr key={`${r.subject_name_en}-${r.start_at}`} className={r.changed ? 'bg-amber-50 font-medium' : ''} data-testid="portal-datesheet-row" data-changed={r.changed ? 'true' : 'false'}>
                      <td className="py-1">
                        {fmtDate(r.start_at)}
                        {r.changed && r.previous_start_at && <span className="block text-xs text-muted-foreground">was {fmtDate(r.previous_start_at)}</span>}
                      </td>
                      <td className="py-1">
                        {fmtTime(r.start_at)} – {fmtTime(r.end_at)}
                      </td>
                      <td className="py-1">
                        {r.subject_name_en}
                        {r.subject_name_ur && <span dir="rtl" className="block text-muted-foreground">{r.subject_name_ur}</span>}
                      </td>
                      <td className="py-1">{r.hall_name ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>

              {(sheet.versions?.length ?? 0) > 1 && (
                <div className="space-y-1 text-sm" data-testid="portal-datesheet-versions">
                  <p className="text-muted-foreground">Earlier versions</p>
                  {sheet.versions!.map((v) => (
                    <p key={v.id}>
                      <Link className="underline" href={`${base}&datesheet=${sheet.datesheet_id}&version=${v.version_no}`}>
                        Version {v.version_no}
                      </Link>{' '}
                      — {fmtDate(v.published_at)} {v.status === 'published' ? '(current)' : ''}
                    </p>
                  ))}
                </div>
              )}
            </>
          )}
        </>
      )}
    </div>
  );
}

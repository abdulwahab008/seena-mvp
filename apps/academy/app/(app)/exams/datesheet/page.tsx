import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { getExamOfficeScope, one } from '@/lib/exams/office-scope';
import type { SlotWarning } from './actions';
import { CreateDatesheetForm, ExamSettingsForm, HallForm, PublishPanel, RemoveSlotButton, SlotForm, WarningList } from './datesheet-editor';

/**
 * FR-I03. Build the datesheet of one exam term. Every save runs the clash
 * check in the database: a pupil who sits two overlapping papers blocks the
 * save and the GR numbers come back; hall capacity and the Friday Jummah
 * cut-off are warnings shown beside the slot.
 */
type SearchParams = { term?: string };

const fmtDate = (iso: string, tz: string) => new Date(iso).toLocaleDateString('en-GB', { timeZone: tz, weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
const fmtTime = (iso: string, tz: string) => new Date(iso).toLocaleTimeString('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit' });

export default async function DatesheetPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const scope = await getExamOfficeScope(supabase);

  const header = (
    <div>
      <h1 className="text-2xl font-semibold">Datesheet</h1>
      <p className="text-sm text-muted-foreground">
        FR-I03 — schedule each paper of a term. A pupil registered for two papers that overlap blocks the save; hall capacity and the Friday Jummah cut-off are
        warnings.
      </p>
    </div>
  );

  if (!scope.campus || !scope.session) {
    return (
      <div className="space-y-6">
        {header}
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      </div>
    );
  }
  const campus = scope.campus;
  const tz = campus.timezone;

  const { data: terms } = await supabase.from('exam_term').select('id, code, name, status').eq('campus_id', campus.id).eq('session_id', scope.session.id).order('sequence');
  const term = (terms ?? []).find((t) => t.id === sp.term) ?? terms?.[0] ?? null;

  const { data: settings } = await supabase
    .from('exam_settings')
    .select('jummah_cutoff, invigilation_max_duties, paper_release_offset_minutes, max_moderation_delta, max_moderation_pct')
    .eq('campus_id', campus.id)
    .maybeSingle();

  const { data: halls } = await supabase.from('exam_hall').select('id, code, name, capacity, rows_count, seats_per_row').eq('campus_id', campus.id).eq('is_active', true).order('code');

  const { data: datesheet } = term ? await supabase.from('datesheet').select('id, title, status, current_version').eq('exam_term_id', term.id).eq('campus_id', campus.id).maybeSingle() : { data: null };

  const { data: papersRaw } = term
    ? await supabase.from('exam_subject').select('id, class_subject:class_subject_id(class_level:class_level_id(name_en, ordinal), subject:subject_id(name_en))').eq('exam_term_id', term.id)
    : { data: [] };
  const papers = (papersRaw ?? [])
    .map((p) => {
      const cs = one(p.class_subject);
      const level = cs ? one(cs.class_level) : null;
      const subject = cs ? one(cs.subject) : null;
      return { id: p.id, label: `${level?.name_en ?? ''} · ${subject?.name_en ?? ''}`, ordinal: level?.ordinal ?? 0 };
    })
    .sort((a, b) => a.ordinal - b.ordinal || a.label.localeCompare(b.label));

  const { data: slots } = datesheet
    ? await supabase.from('datesheet_slot').select('id, exam_subject_id, start_at, end_at, hall_id, invigilators_required').eq('datesheet_id', datesheet.id).order('start_at')
    : { data: [] };
  const { data: warnRows } = datesheet ? await supabase.rpc('fn_datesheet_warnings', { p_datesheet_id: datesheet.id }) : { data: [] };
  const warningsBySlot = new Map((warnRows ?? []).map((w) => [w.slot_id, (w.warnings ?? []) as unknown as SlotWarning[]]));
  const { data: clashRows } = datesheet ? await supabase.rpc('fn_detect_datesheet_clash', { p_datesheet_id: datesheet.id }) : { data: [] };

  const { data: versions } = datesheet ? await supabase.from('datesheet_version').select('id, version_no, status, note, published_at, slot_count').eq('datesheet_id', datesheet.id).order('version_no', { ascending: false }) : { data: [] };

  const paperLabel = new Map(papers.map((p) => [p.id, p.label]));
  const hallLabel = new Map((halls ?? []).map((h) => [h.id, `${h.name} (${h.capacity})`]));
  const editable = scope.canWrite && datesheet?.status === 'draft';

  return (
    <div className="space-y-6">
      {header}

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Exam term</span>
          <select name="term" defaultValue={term?.id} className="h-9 rounded-md border bg-background px-2">
            {(terms ?? []).map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
        <span className="text-muted-foreground">{campus.name} · {scope.session.name}</span>
      </form>

      {!term && <p className="text-sm text-muted-foreground">No exam terms are defined for this session yet.</p>}

      {term && !datesheet && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">No datesheet for {term.name} yet</CardTitle>
          </CardHeader>
          <CardContent>{scope.canWrite ? <CreateDatesheetForm campusId={campus.id} examTermId={term.id} defaultTitle={`${term.name} datesheet`} /> : <p className="text-sm text-muted-foreground">The exam office has not created one.</p>}</CardContent>
        </Card>
      )}

      {datesheet && (
        <>
          <div className="flex flex-wrap items-center gap-3" data-testid="datesheet-header">
            <h2 className="text-lg font-medium">{datesheet.title}</h2>
            <Badge variant={datesheet.status === 'published' ? 'success' : 'outline'} data-testid="datesheet-status">
              {datesheet.status}
            </Badge>
            {datesheet.current_version > 0 && <span className="text-sm text-muted-foreground">version {datesheet.current_version}</span>}
          </div>

          {(clashRows ?? []).length > 0 && (
            <div role="alert" className="rounded-md border border-destructive p-3 text-sm text-destructive" data-testid="clash-banner">
              {(clashRows ?? []).map((c) => (
                <p key={`${c.slot_a}-${c.slot_b}`}>
                  {c.affected_count} candidates are in two overlapping papers: {(c.affected_gr_numbers ?? []).join(', ')}
                </p>
              ))}
            </div>
          )}

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Papers</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm" data-testid="slot-list">
              {(slots ?? []).length === 0 && <p className="text-muted-foreground">No papers scheduled yet.</p>}
              {(slots ?? []).map((s) => (
                <div key={s.id} className="space-y-1 border-b pb-3" data-testid="slot-row">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">{paperLabel.get(s.exam_subject_id) ?? 'Paper'}</span>
                    <span className="flex items-center gap-3">
                      <span>
                        {fmtDate(s.start_at, tz)} · {fmtTime(s.start_at, tz)}–{fmtTime(s.end_at, tz)}
                      </span>
                      {editable && <RemoveSlotButton slotId={s.id} />}
                    </span>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    {s.hall_id ? (hallLabel.get(s.hall_id) ?? 'Hall') : 'No hall assigned'} · {s.invigilators_required} invigilator{s.invigilators_required === 1 ? '' : 's'}
                  </p>
                  <WarningList warnings={warningsBySlot.get(s.id) ?? []} />
                </div>
              ))}
            </CardContent>
          </Card>

          {editable && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Schedule or move a paper</CardTitle>
              </CardHeader>
              <CardContent>
                <SlotForm datesheetId={datesheet.id} papers={papers.map((p) => ({ id: p.id, label: p.label }))} halls={(halls ?? []).map((h) => ({ id: h.id, label: `${h.name} (${h.capacity})` }))} />
              </CardContent>
            </Card>
          )}
          {!editable && datesheet.status === 'published' && <p className="text-sm text-muted-foreground">This datesheet is published and read-only.</p>}

          {scope.canWrite && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Publication</CardTitle>
              </CardHeader>
              <CardContent className="space-y-3 text-sm">
                <p className="text-muted-foreground">
                  Publishing freezes the papers into a numbered, immutable version that parents see. To change a published datesheet, reopen it, edit and publish again: the earlier version stays on record.
                </p>
                <PublishPanel datesheetId={datesheet.id} status={datesheet.status} canPublish={(slots ?? []).length > 0 && (clashRows ?? []).length === 0} nextVersion={datesheet.current_version + 1} />
              </CardContent>
            </Card>
          )}

          {(versions ?? []).length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Published versions</CardTitle>
              </CardHeader>
              <CardContent className="space-y-2 text-sm" data-testid="version-list">
                {(versions ?? []).map((v) => (
                  <div key={v.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="version-row">
                    <span>
                      Version {v.version_no} · {v.slot_count} papers · {fmtDate(v.published_at, tz)}
                      {v.note ? ` · ${v.note}` : ''}
                    </span>
                    <span className="flex items-center gap-3">
                      <Badge variant={v.status === 'published' ? 'success' : 'outline'}>{v.status}</Badge>
                      <a className="underline" href={`/api/datesheets/${v.id}/pdf`} target="_blank" rel="noreferrer">
                        PDF
                      </a>
                    </span>
                  </div>
                ))}
              </CardContent>
            </Card>
          )}
        </>
      )}

      {scope.canWrite && settings && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Exam office settings</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p className="text-muted-foreground">
              Used across the examination screens: the Friday cut-off the datesheet warns against, the invigilation cap, when a published paper unseals, and the moderation limits.
            </p>
            <ExamSettingsForm
              campusId={campus.id}
              values={{
                jummahCutoff: settings.jummah_cutoff.slice(0, 5),
                invigilationMaxDuties: settings.invigilation_max_duties,
                paperReleaseOffsetMinutes: settings.paper_release_offset_minutes,
                maxModerationDelta: Number(settings.max_moderation_delta),
                maxModerationPct: settings.max_moderation_pct === null ? null : Number(settings.max_moderation_pct),
              }}
            />
          </CardContent>
        </Card>
      )}

      {scope.canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Exam halls</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <ul className="space-y-1" data-testid="hall-list">
              {(halls ?? []).length === 0 && <li className="text-muted-foreground">No halls yet.</li>}
              {(halls ?? []).map((h) => (
                <li key={h.id}>
                  {h.code} · {h.name} — {h.rows_count} rows × {h.seats_per_row} seats = {h.capacity}
                </li>
              ))}
            </ul>
            <HallForm campusId={campus.id} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}

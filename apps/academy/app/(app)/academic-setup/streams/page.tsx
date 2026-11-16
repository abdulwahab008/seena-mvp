import { supabaseServer } from '@/lib/supabase/server';
import { BOARD_LABEL } from '@/lib/validation';
import { ActionForm } from '@/components/action-form';
import { ActionButton } from '@/components/spec-form';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { createStream, deleteStream, setCampusBoard, setHomeworkLoad, setHomeworkNotificationCap, setMarkPrecision, setSectionStream, setStreamActive } from './actions';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);
const boardOptions = Object.entries(BOARD_LABEL).map(([value, label]) => ({ value, label }));

export default async function StreamsPage() {
  const supabase = await supabaseServer();
  const [{ data: streams }, { data: classes }, { data: campuses }, { data: settings }, { data: sections }, { data: loads }, { data: notifyCap }] = await Promise.all([
    supabase.from('stream').select('id, code, name_en, board, applies_from_ordinal, is_active').order('code'),
    supabase.from('class_level').select('name_en, ordinal').eq('is_active', true).order('ordinal'),
    supabase.from('campus').select('id, name').eq('status', 'active').order('name'),
    supabase.from('campus_setting').select('campus_id, key, value').in('key', ['board', 'mark_precision']),
    supabase
      .from('class_section')
      .select('id, name, stream_id, campus:campus_id(name), class_level:class_level_id(name_en, ordinal), session:session_id(is_current)')
      .eq('is_active', true),
    supabase.from('homework_load_policy').select('campus_id, max_assignments_per_day, max_minutes_per_day, session:session_id(is_current)'),
    supabase.from('homework_notification_policy').select('daily_cap_per_campus').maybeSingle(),
  ]);
  const boards = (settings ?? []).filter((x) => x.key === 'board');
  const precisionOf = new Map((settings ?? []).filter((x) => x.key === 'mark_precision').map((x) => [x.campus_id, Number(x.value)]));
  const loadOf = new Map((loads ?? []).filter((l) => one(l.session)?.is_current).map((l) => [l.campus_id, l]));
  const campusOptions = (campuses ?? []).map((c) => ({ value: c.id, label: c.name }));
  const className = new Map((classes ?? []).map((c) => [c.ordinal, c.name_en]));
  const boardOf = new Map((boards ?? []).map((b) => [b.campus_id, String(b.value) as keyof typeof BOARD_LABEL]));
  const streamName = new Map((streams ?? []).map((s) => [s.id, s.name_en]));
  const currentSections = (sections ?? [])
    .filter((s) => one(s.session)?.is_current)
    .sort((a, b) => (one(a.class_level)?.ordinal ?? 0) - (one(b.class_level)?.ordinal ?? 0) || a.name.localeCompare(b.name));
  const multiCampus = (campuses ?? []).length > 1;
  const sectionLabel = (s: (typeof currentSections)[number]) =>
    `${multiCampus ? `${one(s.campus)?.name} · ` : ''}${one(s.class_level)?.name_en} ${s.name}${s.stream_id ? ` · ${streamName.get(s.stream_id) ?? ''}` : ''}`;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Board, streams and academic rules"
        description="The board each campus sits its exams with, the groups offered from Class 9 (Science, Arts, Pre-Medical, Pre-Engineering), and the rules for marks and homework."
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Exam board by campus</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-6 md:grid-cols-2">
          <ul className="space-y-1 text-sm" data-testid="campus-boards">
            {(campuses ?? []).map((c) => {
              const b = boardOf.get(c.id);
              return (
                <li key={c.id}>
                  <span className="font-medium">{c.name}:</span> {b ? BOARD_LABEL[b] ?? b : <span className="text-muted-foreground">not set</span>}
                </li>
              );
            })}
          </ul>
          <ActionForm
            testId="campus-board-form"
            submitLabel="Save board"
            action={setCampusBoard}
            fields={[
              { name: 'campusId', label: 'Campus', type: 'select', required: true, options: campusOptions },
              { name: 'board', label: 'Board', type: 'select', required: true, options: boardOptions },
            ]}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Streams</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          {(streams ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">No streams yet.</p>
          ) : (
            <table className="w-full text-sm" data-testid="stream-list">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="py-1 pr-3">Code</th>
                  <th className="pr-3">Name</th>
                  <th className="pr-3">Board</th>
                  <th className="pr-3">From</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {(streams ?? []).map((s) => (
                  <tr key={s.id} className="border-t" data-testid={`stream-${s.code}`}>
                    <td className="py-1 pr-3 font-mono">{s.code}</td>
                    <td className="pr-3">
                      {s.name_en} {!s.is_active && <Badge variant="outline">Inactive</Badge>}
                    </td>
                    <td className="pr-3">{BOARD_LABEL[s.board]}</td>
                    <td className="pr-3">{className.get(s.applies_from_ordinal) ?? `Class ordinal ${s.applies_from_ordinal}`}</td>
                    <td className="flex justify-end gap-1 py-1">
                      <ActionButton
                        label={s.is_active ? 'Deactivate' : 'Activate'}
                        testId={`stream-toggle-${s.code}`}
                        action={setStreamActive}
                        args={[s.id, !s.is_active]}
                      />
                      <ActionButton label="Delete" variant="ghost" confirm={`Delete the ${s.name_en} stream?`} action={deleteStream} args={[s.id]} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <div className="grid gap-6 md:grid-cols-2">
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Add a stream</h3>
              <ActionForm
                testId="stream-form"
                submitLabel="Add stream"
                action={createStream}
                fields={[
                  { name: 'code', label: 'Code', required: true, placeholder: 'SCI' },
                  { name: 'nameEn', label: 'Name', required: true, placeholder: 'Science' },
                  { name: 'nameUr', label: 'Name (Urdu)' },
                  { name: 'board', label: 'Board', type: 'select', required: true, options: boardOptions },
                  {
                    name: 'fromOrdinal',
                    label: 'Starts from class',
                    type: 'select',
                    required: true,
                    options: (classes ?? []).map((c) => ({ value: String(c.ordinal), label: c.name_en })),
                  },
                ]}
              />
            </div>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Set a section&apos;s stream (this session)</h3>
              <ActionForm
                testId="section-stream-form"
                submitLabel="Save"
                action={setSectionStream}
                fields={[
                  { name: 'sectionId', label: 'Section', type: 'select', required: true, options: currentSections.map((s) => ({ value: s.id, label: sectionLabel(s) })) },
                  {
                    name: 'streamId',
                    label: 'Stream',
                    type: 'select',
                    options: (streams ?? []).filter((s) => s.is_active).map((s) => ({ value: s.id, label: s.name_en })),
                  },
                ]}
              />
              <p className="text-xs text-muted-foreground">Leave the stream empty to take a section off its stream.</p>
            </div>
          </div>
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Marks and homework</CardTitle>
        </CardHeader>
        <CardContent className="space-y-6">
          <ul className="space-y-1 text-sm" data-testid="campus-rules">
            {(campuses ?? []).map((c) => {
              const p = precisionOf.get(c.id) ?? 0;
              const l = loadOf.get(c.id);
              const limits = [l?.max_assignments_per_day && `${l.max_assignments_per_day} assignments`, l?.max_minutes_per_day && `${l.max_minutes_per_day} minutes`].filter(Boolean);
              return (
                <li key={c.id}>
                  <span className="font-medium">{c.name}:</span> marks {p === 0 ? 'in whole numbers' : `up to ${p} decimal place${p === 1 ? '' : 's'}`}; homework{' '}
                  {limits.length ? `at most ${limits.join(' or ')} a day per section` : 'not limited'}
                </li>
              );
            })}
            <li>
              <span className="font-medium">Homework messages to parents:</span> at most {notifyCap?.daily_cap_per_campus ?? 100} a day per campus
            </li>
          </ul>
          <div className="grid gap-6 md:grid-cols-3">
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Marks entry</h3>
              <ActionForm
                testId="mark-precision-form"
                submitLabel="Save"
                action={setMarkPrecision}
                fields={[
                  { name: 'campusId', label: 'Campus', type: 'select', required: true, options: campusOptions },
                  {
                    name: 'precision',
                    label: 'Decimal places',
                    type: 'select',
                    required: true,
                    options: [
                      { value: '0', label: 'Whole marks only (45)' },
                      { value: '1', label: 'One decimal (45.5)' },
                      { value: '2', label: 'Two decimals (45.25)' },
                    ],
                  },
                ]}
              />
            </div>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Homework per day (this session)</h3>
              <ActionForm
                testId="homework-load-form"
                submitLabel="Save"
                action={setHomeworkLoad}
                fields={[
                  { name: 'campusId', label: 'Campus', type: 'select', required: true, options: campusOptions },
                  { name: 'maxAssignments', label: 'Most assignments a day', type: 'number' },
                  { name: 'maxMinutes', label: 'Most minutes a day', type: 'number' },
                ]}
              />
            </div>
            <div className="space-y-2">
              <h3 className="text-sm font-medium">Homework messages to parents</h3>
              <ActionForm
                testId="homework-notify-form"
                submitLabel="Save"
                action={setHomeworkNotificationCap}
                fields={[{ name: 'cap', label: 'Most messages a day per campus', type: 'number', required: true, defaultValue: String(notifyCap?.daily_cap_per_campus ?? 100) }]}
              />
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}

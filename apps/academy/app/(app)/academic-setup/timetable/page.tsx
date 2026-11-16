import { supabaseServer } from '@/lib/supabase/server';
import { CreateVersionForm } from './create-version-form';
import { TimetableGrid, type SlotRow } from './timetable-grid';
import { AutofillControls } from './autofill-controls';
import { pickActiveCampus } from '@/lib/campus-context';
import { ActionForm } from '@/components/action-form';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { currentRole, loose } from '@/lib/transport/rpc';
import { saveTimetableRules } from './rules-actions';

export default async function TimetablePage({
  searchParams,
}: {
  searchParams: Promise<{ version?: string; section?: string }>;
}) {
  const { version: versionParam, section: sectionParam } = await searchParams;
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase
    .from('campus')
    .select('id')
    .eq('status', 'active')
    .order('code');
  const campusId = (await pickActiveCampus(campuses))?.id;

  const { data: sessions } = campusId
    ? await supabase.from('academic_session').select('id').eq('is_current', true).limit(1)
    : { data: [] as never[] };
  const sessionId = sessions?.[0]?.id;

  const { data: versions } =
    campusId && sessionId
      ? await supabase
          .from('timetable_version')
          .select(
            'id, name, shift, status, version_no, effective_from, effective_to, warning_count',
          )
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .order('created_at', { ascending: false })
      : { data: [] as never[] };

  const versionId = versionParam ?? versions?.[0]?.id;
  const selectedVersion = versions?.find((v) => v.id === versionId);

  const { data: sections } =
    campusId && sessionId
      ? await supabase
          .from('class_section')
          .select('id, name, class_level_id, class_level:class_level_id(name_en, code)')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .eq('is_active', true)
          .order('name')
      : { data: [] as never[] };

  const sectionId = sectionParam ?? sections?.[0]?.id;

  const { data: subjects } = await supabase
    .from('subject')
    .select('id, code, name_en')
    .eq('is_active', true)
    .order('name_en');
  const { data: rooms } = campusId
    ? await supabase
        .from('room')
        .select('id, code, name')
        .eq('campus_id', campusId)
        .eq('is_active', true)
        .order('code')
    : { data: [] as never[] };
  const { data: staff } = await supabase
    .from('app_user')
    .select('user_id, full_name')
    .in('app_role', ['subject_teacher', 'class_teacher', 'head_of_department'])
    .order('full_name');

  const { data: slots } =
    versionId && sectionId
      ? await supabase
          .from('timetable_slot')
          .select(
            'id, weekday, period_no, subject_id, staff_id, room_id, elective_bucket, parallel_group_id, subject:subject_id(code, name_en), room:room_id(code)',
          )
          .eq('timetable_version_id', versionId)
          .eq('section_id', sectionId)
      : { data: [] as never[] };

  // FR-F06: a warning is keyed by (version, room, weekday, period), not by
  // section — it applies to whichever section's slot happens to be
  // rendered in that room-cell.
  const { data: roomWarnings } = versionId
    ? await supabase
        .from('timetable_room_capacity_warning')
        .select('room_id, weekday, period_no, total_students, room_capacity')
        .eq('timetable_version_id', versionId)
    : { data: [] as never[] };

  const role = await currentRole(loose(supabase));
  const canSetRules = ['super_admin', 'owner', 'principal'].includes(role);
  const { data: ruleRows } = campusId
    ? await supabase.from('timetable_constraint').select('key, int_value, is_enabled').eq('campus_id', campusId)
    : { data: [] as never[] };
  const rule = (k: string) => (ruleRows ?? []).find((r) => r.key === k);
  const maxPerDay = rule('max_periods_per_day')?.int_value ?? 7;
  const maxConsecutive = rule('max_consecutive_periods')?.int_value ?? 4;
  const flagIsolated = rule('flag_isolated_free_period')?.is_enabled ?? true;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Timetable Builder</h1>
        <p className="text-sm text-muted-foreground">
          Assign subjects, teachers and rooms onto a draft timetable, one section at a time.
        </p>
      </div>
      {!campusId || !sessionId ? (
        <p className="text-sm text-muted-foreground">No active campus or session found.</p>
      ) : (
        <>
          <CreateVersionForm campusId={campusId} sessionId={sessionId} />

          {!versions || versions.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No draft timetable versions yet — create one above.
            </p>
          ) : (
            <>
              {selectedVersion?.status === 'DRAFT' && sectionId && (
                <AutofillControls
                  versionId={versionId!}
                  sectionId={sectionId}
                  otherSections={(sections ?? [])
                    .filter((s) => s.id !== sectionId)
                    .map((s) => ({
                      id: s.id,
                      label:
                        `${(Array.isArray(s.class_level) ? s.class_level[0] : s.class_level)?.name_en ?? ''} ${s.name}`.trim(),
                    }))}
                />
              )}
              <TimetableGrid
                versions={versions}
                selectedVersionId={versionId!}
                sections={(sections ?? []) as never[]}
                selectedSectionId={sectionId ?? null}
                subjects={subjects ?? []}
                rooms={rooms ?? []}
                staff={staff ?? []}
                slots={(slots ?? []) as unknown as SlotRow[]}
                roomWarnings={roomWarnings ?? []}
                isDraft={selectedVersion?.status === 'DRAFT'}
              />
            </>
          )}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Teacher load warnings</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <p data-testid="timetable-rules">
                A teacher is flagged above {maxPerDay} periods a day or {maxConsecutive} periods in a row{flagIsolated ? ', and for a single free period stuck between classes' : ''}.
              </p>
              {canSetRules && (
                <ActionForm
                  testId="timetable-rules-form"
                  submitLabel="Save rules"
                  action={saveTimetableRules}
                  resetOnSuccess={false}
                  fields={[
                    { name: 'campusId', label: 'Campus', type: 'hidden', defaultValue: campusId },
                    { name: 'maxPerDay', label: 'Most periods a day', type: 'number', required: true, defaultValue: String(maxPerDay) },
                    { name: 'maxConsecutive', label: 'Most periods in a row', type: 'number', required: true, defaultValue: String(maxConsecutive) },
                    {
                      name: 'flagIsolated',
                      label: 'Flag a single free period between classes',
                      type: 'select',
                      required: true,
                      defaultValue: flagIsolated ? 'yes' : 'no',
                      options: [
                        { value: 'yes', label: 'Yes' },
                        { value: 'no', label: 'No' },
                      ],
                    },
                  ]}
                />
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

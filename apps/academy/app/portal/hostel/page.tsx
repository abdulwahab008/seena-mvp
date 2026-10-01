import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t, type MessageKey } from '@/lib/i18n/messages';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SpecForm } from '@/components/spec-form';
import { loose, todayPk } from '@/lib/transport/rpc';
import { requestMessOff } from './actions';

export const dynamic = 'force-dynamic';

type Slot = { day_of_week: number; meal: 'breakfast' | 'lunch' | 'dinner'; items: string; items_ur: string | null; published_at: string };
type Off = { id: string; student_id: string; starts_on: string; ends_on: string; status: 'pending' | 'approved' | 'rejected' };
type Boarder = { student_id: string; student: { name_en: string; name_ur: string | null } | { name_en: string; name_ur: string | null }[] | null };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

function mondayOf(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}

// FR-Q05: the published weekly menu (in the parent's language) and the mess-off request form.
export default async function PortalHostelPage() {
  const lang = await getLang();
  const supabase = loose(await supabaseServer());
  const today = todayPk();
  const week = mondayOf(today);
  const [{ data: menu }, { data: stays }, { data: offs }, { data: setting }] = await Promise.all([
    supabase.from('hostel_mess_menu').select('day_of_week, meal, items, items_ur, published_at').eq('week_start', week).not('published_at', 'is', null),
    supabase.from('hostel_allocation').select('student_id, student:student_id(name_en, name_ur)').or(`ends_on.is.null,ends_on.gte.${today}`),
    supabase.from('hostel_mess_off').select('id, student_id, starts_on, ends_on, status').gte('ends_on', today).order('starts_on'),
    supabase.from('tenant_setting').select('value').eq('key', 'hostel.mess_notice_hours').maybeSingle(),
  ]);
  const slots = (menu ?? []) as Slot[];
  const publishedAt = slots[0]?.published_at;
  const boarders = [...new Map(((stays ?? []) as Boarder[]).map((b) => [b.student_id, b])).values()];
  const hours = String((setting as { value: unknown } | null)?.value ?? 24);
  const monthDays = new Map<string, number>();
  for (const b of boarders) {
    const { data } = await supabase.rpc('billable_mess_days', { p_student_id: b.student_id, p_month: today });
    monthDays.set(b.student_id, Number(data ?? 0));
  }
  const meals = ['breakfast', 'lunch', 'dinner'] as const;
  const text = (s: Slot) => (lang === 'ur' && s.items_ur ? s.items_ur : s.items);

  return (
    <div className="space-y-6">
      <h2 className="text-xl font-semibold">{t(lang, 'hostel.title')}</h2>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{t(lang, 'hostel.menu')}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="portal-menu">
          {slots.length === 0 ? (
            <p className="text-muted-foreground">{t(lang, 'hostel.noMenu')}</p>
          ) : (
            <>
              <p className="text-xs text-muted-foreground" data-testid="menu-published">
                {t(lang, 'hostel.published', { when: new Date(publishedAt!).toLocaleString(lang === 'ur' ? 'ur-PK-u-nu-latn' : 'en-GB', { timeZone: 'Asia/Karachi' }) })}
              </p>
              <table className="w-full">
                <thead>
                  <tr>
                    <th />
                    {meals.map((m) => (
                      <th key={m} className="text-start">
                        {t(lang, `hostel.${m}` as MessageKey)}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {[1, 2, 3, 4, 5, 6, 7].map((d) => (
                    <tr key={d} className="border-t align-top">
                      <td className="py-1 pe-2 font-medium">{t(lang, `hostel.day${d}` as MessageKey)}</td>
                      {meals.map((m) => {
                        const s = slots.find((x) => x.day_of_week === d && x.meal === m);
                        return (
                          <td key={m} data-testid="menu-slot">
                            {s ? text(s) : '-'}
                          </td>
                        );
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{t(lang, 'hostel.messOff')}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4 text-sm">
          {boarders.length === 0 && <p className="text-muted-foreground">{t(lang, 'hostel.noBoarders')}</p>}
          {boarders.map((b) => {
            const child = one(b.student);
            const mine = ((offs ?? []) as Off[]).filter((o) => o.student_id === b.student_id);
            return (
              <div key={b.student_id} className="space-y-2 border-b pb-4" data-testid="boarder-card">
                <p className="font-medium">{lang === 'ur' && child?.name_ur ? child.name_ur : child?.name_en}</p>
                <p className="text-muted-foreground">{t(lang, 'hostel.mealDays', { n: String(monthDays.get(b.student_id) ?? 0) })}</p>
                <ul>
                  {mine.map((o) => (
                    <li key={o.id} data-testid="my-mess-off">
                      {o.starts_on} to {o.ends_on} · {t(lang, `hostel.status.${o.status}` as MessageKey)}
                    </li>
                  ))}
                </ul>
                <p className="text-muted-foreground">{t(lang, 'hostel.messOffHelp', { hours })}</p>
                <SpecForm
                  testId={`mess-off-form-${b.student_id}`}
                  submitLabel={t(lang, 'hostel.submit')}
                  action={requestMessOff}
                  columns={3}
                  fields={[
                    { name: 'studentId', label: 'Child', type: 'hidden', defaultValue: b.student_id },
                    { name: 'from', label: t(lang, 'hostel.from'), type: 'date', required: true },
                    { name: 'to', label: t(lang, 'hostel.to'), type: 'date', required: true },
                    { name: 'reason', label: t(lang, 'hostel.reason') },
                  ]}
                />
              </div>
            );
          })}
        </CardContent>
      </Card>
    </div>
  );
}

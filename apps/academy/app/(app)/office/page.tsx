import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatDatePk, todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ContactForm, DoneButton, TaskForm } from './office-forms';
import { CATEGORY_LABEL, type ContactInput } from './schema';

export const dynamic = 'force-dynamic';

export default async function OfficePage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const q = ((await searchParams).q ?? '').trim();
  const supabase = await supabaseServer();
  let contacts = supabase.from('office_contact').select('id, name, organisation, category, phone, email').order('name').limit(200);
  if (q) contacts = contacts.or(`name.ilike.%${q.replace(/[%,()]/g, '')}%,organisation.ilike.%${q.replace(/[%,()]/g, '')}%`);
  const [{ data: tasks }, { data: staff }, { data: contactRows }] = await Promise.all([
    supabase.from('team_task').select('id, title, due_on, assigned_to, created_by').is('done_at', null).order('due_on', { ascending: true, nullsFirst: false }).limit(200),
    supabase.from('app_user').select('user_id, full_name').not('app_role', 'in', '(parent,student)').order('full_name'),
    contacts,
  ]);
  const names = new Map((staff ?? []).map((s) => [s.user_id, s.full_name]));
  const today = todayPk();

  return (
    <>
      <PageHeader title="Tasks and contacts" description="The office's shared to-do list and phone book." />
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Team tasks</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <TaskForm staff={(staff ?? []).map((s) => ({ id: s.user_id, name: s.full_name }))} />
            {(tasks ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">Nothing to do.</p>
            ) : (
              <ul className="space-y-2">
                {(tasks ?? []).map((t) => (
                  <li key={t.id} className="flex items-center justify-between gap-2 rounded-md border p-2 text-sm" data-testid="team-task">
                    <span>
                      {t.title}
                      <span className={cn('block text-xs text-muted-foreground', t.due_on && t.due_on < today && 'font-medium text-destructive')}>
                        {t.assigned_to ? `For ${names.get(t.assigned_to) ?? 'a colleague'}` : 'For anyone'}
                        {t.due_on ? ` · due ${formatDatePk(t.due_on)}` : ''}
                      </span>
                    </span>
                    {(t.assigned_to === actor.userId || t.created_by === actor.userId || ['super_admin', 'owner', 'principal', 'vice_principal'].includes(actor.role)) && <DoneButton id={t.id} />}
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Contacts</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <ContactForm />
            <form method="get" className="flex gap-2 text-sm">
              <input name="q" defaultValue={q} placeholder="Search name or organisation" aria-label="Search contacts" className="h-9 flex-1 rounded-md border bg-background px-2" />
              <button type="submit" className="h-9 rounded-md border px-3">
                Search
              </button>
            </form>
            {(contactRows ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">{q ? 'No contact matches.' : 'No contacts yet.'}</p>
            ) : (
              <ul className="divide-y text-sm">
                {(contactRows ?? []).map((c) => (
                  <li key={c.id} className="py-2" data-testid="office-contact">
                    <span className="font-medium">{c.name}</span>
                    {c.organisation ? ` · ${c.organisation}` : ''}
                    <span className="block text-xs text-muted-foreground">
                      {CATEGORY_LABEL[c.category as ContactInput['category']] ?? c.category}
                      {c.phone ? ` · ${c.phone}` : ''}
                      {c.email ? ` · ${c.email}` : ''}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </>
  );
}

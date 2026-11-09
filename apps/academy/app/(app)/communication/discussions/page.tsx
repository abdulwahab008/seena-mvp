import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatDateTimePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { ThreadForm } from './forms';

export const dynamic = 'force-dynamic';

export default async function DiscussionsPage() {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student', 'none'].includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: threads } = await supabase
    .from('discussion_thread')
    .select('id, title, author_id, reply_count, last_activity_at')
    .order('last_activity_at', { ascending: false })
    .limit(100);
  const authorIds = [...new Set((threads ?? []).map((t) => t.author_id))];
  const { data: authors } = authorIds.length ? await supabase.from('app_user').select('user_id, full_name').in('user_id', authorIds) : { data: [] };
  const names = new Map((authors ?? []).map((a) => [a.user_id, a.full_name]));

  return (
    <>
      <PageHeader title="Staff discussions" description="A noticeboard for the staff room. Parents and students never see it." />
      <div className="grid gap-6 lg:grid-cols-[1fr_22rem]">
        {(threads ?? []).length === 0 ? (
          <EmptyState title="No discussions yet" description="Start the first thread." />
        ) : (
          <ul className="divide-y rounded-lg border bg-card">
            {(threads ?? []).map((t) => (
              <li key={t.id} data-testid="discussion-thread">
                <Link href={`/communication/discussions/${t.id}`} className="block p-4 hover:bg-muted">
                  <span className="font-medium">{t.title}</span>
                  <span className="block text-xs text-muted-foreground">
                    {names.get(t.author_id) ?? 'A colleague'} · {t.reply_count} {t.reply_count === 1 ? 'reply' : 'replies'} · last activity {formatDateTimePk(t.last_activity_at)}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
        <Card className="h-fit">
          <CardHeader>
            <CardTitle className="text-base">New thread</CardTitle>
          </CardHeader>
          <CardContent>
            <ThreadForm />
          </CardContent>
        </Card>
      </div>
    </>
  );
}

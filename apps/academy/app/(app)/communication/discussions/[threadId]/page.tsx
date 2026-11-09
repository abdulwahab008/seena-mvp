import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatDateTimePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Card, CardContent } from '@/components/ui/card';
import { ReplyForm } from '../forms';

export const dynamic = 'force-dynamic';

export default async function DiscussionThreadPage({ params }: { params: Promise<{ threadId: string }> }) {
  const { threadId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(threadId)) notFound();
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student', 'none'].includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const [{ data: thread }, { data: replies }] = await Promise.all([
    supabase.from('discussion_thread').select('id, title, body, author_id, created_at').eq('id', threadId).maybeSingle(),
    supabase.from('discussion_reply').select('id, body, author_id, created_at').eq('thread_id', threadId).order('created_at'),
  ]);
  if (!thread) notFound();
  const authorIds = [...new Set([thread.author_id, ...(replies ?? []).map((r) => r.author_id)])];
  const { data: authors } = await supabase.from('app_user').select('user_id, full_name').in('user_id', authorIds);
  const names = new Map((authors ?? []).map((a) => [a.user_id, a.full_name]));
  const byline = (authorId: string, at: string) => `${names.get(authorId) ?? 'A colleague'} · ${formatDateTimePk(at)}`;

  return (
    <>
      <PageHeader
        title={thread.title}
        description={byline(thread.author_id, thread.created_at)}
        actions={
          <Link href="/communication/discussions" className="text-sm underline">
            All discussions
          </Link>
        }
      />
      <div className="max-w-3xl space-y-4">
        <Card>
          <CardContent className="whitespace-pre-wrap p-4 text-sm">{thread.body}</CardContent>
        </Card>
        {(replies ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No replies yet.</p>
        ) : (
          <ul className="space-y-3">
            {(replies ?? []).map((r) => (
              <li key={r.id} className="rounded-md border bg-card p-4 text-sm" data-testid="discussion-reply">
                <p className="whitespace-pre-wrap">{r.body}</p>
                <p className="mt-2 text-xs text-muted-foreground">{byline(r.author_id, r.created_at)}</p>
              </li>
            ))}
          </ul>
        )}
        <Card>
          <CardContent className="p-4">
            <ReplyForm threadId={thread.id} />
          </CardContent>
        </Card>
      </div>
    </>
  );
}

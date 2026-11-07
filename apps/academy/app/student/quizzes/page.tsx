import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { formatDateTimePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';

export default async function StudentQuizzesPage() {
  const supabase = await supabaseServer();
  const { data: quizzes } = await supabase.rpc('my_quizzes');
  const now = Date.now();

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Quizzes</h1>
      {(quizzes ?? []).length === 0 && <p className="text-sm text-muted-foreground">No quizzes yet.</p>}
      <ul className="space-y-2">
        {(quizzes ?? []).map((q) => {
          const open = now >= Date.parse(q.opens_at) && now <= Date.parse(q.closes_at);
          return (
            <li key={q.id} className="flex flex-wrap items-center justify-between gap-2 rounded-md border p-3" data-testid="student-quiz">
              <div>
                <p className="font-medium">{q.title}</p>
                <p className="text-xs text-muted-foreground">
                  {q.questions} questions · {q.duration_min} minutes · closes {formatDateTimePk(q.closes_at)}
                </p>
              </div>
              {q.submitted ? (
                <Badge variant="success" data-testid="student-quiz-score">
                  {q.score} / {q.max_score}
                </Badge>
              ) : open ? (
                <Link href={`/student/quizzes/${q.id}`} className="rounded-md border px-3 py-1.5 text-sm font-medium hover:bg-muted">
                  Start
                </Link>
              ) : (
                <Badge variant="outline">{now < Date.parse(q.opens_at) ? `Opens ${formatDateTimePk(q.opens_at)}` : 'Closed'}</Badge>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

import { supabaseServer } from '@/lib/supabase/server';
import { BookOpen, Calendar, Clock, AlertCircle } from 'lucide-react';
import { Badge } from '@/components/ui/badge';

export default async function StudentHomeworkPage() {
  const supabase = await supabaseServer();

  // Get student's enrolled section
  const { data: enrolment } = await supabase
    .from('enrolment')
    .select('id, section_id, class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active')
    .limit(1)
    .maybeSingle();

  const section = enrolment?.class_section
    ? (Array.isArray(enrolment.class_section) ? enrolment.class_section[0] : enrolment.class_section)
    : null;

  const { data: rows } = enrolment?.section_id
    ? await supabase
        .from('v_student_homework_feed')
        .select('id, subject_name_en, title, description, due_date, estimated_minutes, is_overdue')
        .eq('section_id', enrolment.section_id)
        .order('due_date', { ascending: true })
    : { data: [] };

  const assignments = (rows ?? []) as Array<{
    id: string;
    subject_name_en: string;
    title: string;
    description: string | null;
    due_date: string;
    estimated_minutes: number | null;
    is_overdue: boolean;
  }>;

  const overdue = assignments.filter((a) => a.is_overdue);
  const pending = assignments.filter((a) => !a.is_overdue);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-bold tracking-tight">Homework Assignments</h2>
        <p className="text-sm text-muted-foreground">
          Pending coursework and tasks assigned to your section.
        </p>
      </div>

      {assignments.length === 0 ? (
        <div className="rounded-lg border bg-card p-12 text-center text-muted-foreground">
          <BookOpen className="mx-auto h-10 w-10 mb-3 opacity-40" />
          <p className="font-medium">No homework currently assigned!</p>
          <p className="text-xs mt-1">You are all caught up on your coursework.</p>
        </div>
      ) : (
        <div className="space-y-6">
          {overdue.length > 0 && (
            <div className="space-y-3">
              <div className="flex items-center gap-2 text-sm font-semibold text-destructive">
                <AlertCircle className="h-4 w-4" />
                Overdue ({overdue.length})
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                {overdue.map((item) => (
                  <div key={item.id} className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 space-y-2">
                    <div className="flex items-start justify-between gap-2">
                      <span className="font-semibold text-foreground">{item.title}</span>
                      <Badge variant="destructive">Overdue</Badge>
                    </div>
                    <div className="text-xs font-medium text-destructive">{item.subject_name_en}</div>
                    {item.description && <p className="text-xs text-muted-foreground line-clamp-2">{item.description}</p>}
                    <div className="flex items-center gap-4 text-xs text-muted-foreground pt-1">
                      <span className="flex items-center gap-1">
                        <Calendar className="h-3 w-3" /> Due {item.due_date}
                      </span>
                      {item.estimated_minutes && (
                        <span className="flex items-center gap-1">
                          <Clock className="h-3 w-3" /> ~{item.estimated_minutes}m
                        </span>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {pending.length > 0 && (
            <div className="space-y-3">
              <div className="text-sm font-semibold text-foreground">
                Upcoming ({pending.length})
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                {pending.map((item) => (
                  <div key={item.id} className="rounded-lg border bg-card p-4 space-y-2 shadow-sm">
                    <div className="flex items-start justify-between gap-2">
                      <span className="font-semibold text-foreground">{item.title}</span>
                      <Badge variant="default">{item.subject_name_en}</Badge>
                    </div>
                    {item.description && <p className="text-xs text-muted-foreground line-clamp-2">{item.description}</p>}
                    <div className="flex items-center gap-4 text-xs text-muted-foreground pt-1">
                      <span className="flex items-center gap-1">
                        <Calendar className="h-3 w-3" /> Due {item.due_date}
                      </span>
                      {item.estimated_minutes && (
                        <span className="flex items-center gap-1">
                          <Clock className="h-3 w-3" /> ~{item.estimated_minutes}m
                        </span>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

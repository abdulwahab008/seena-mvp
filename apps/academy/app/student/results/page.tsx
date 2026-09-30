import { supabaseServer } from '@/lib/supabase/server';
import { Award, CheckCircle2, XCircle } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export default async function StudentResultsPage() {
  const supabase = await supabaseServer();

  // Query own subject results (RLS enforces student self scope and checks fn_result_withheld)
  const { data: marksRows } = await supabase
    .from('subject_result')
    .select(`
      id,
      obtained,
      max_marks,
      is_pass,
      subject:subject_id(code, name_en),
      exam_term:exam_term_id(code, name)
    `)
    .order('computed_at', { ascending: false });

  // Query own result position (RLS enforces only own rank, and ONLY when show_rank is true)
  const { data: positionRows } = await supabase
    .from('result_position')
    .select(`
      id,
      total_obtained,
      total_max,
      rank_in_section,
      rank_in_class,
      ranked_out_of,
      ranked_out_of_class,
      is_ranked,
      exam_term:exam_term_id(code, name)
    `);

  const results = marksRows ?? [];
  const positions = positionRows ?? [];
  const latestPosition = positions[0];

  const totalObtained = results.reduce((acc, r) => acc + (r.obtained ?? 0), 0);
  const totalMax = results.reduce((acc, r) => acc + (r.max_marks ?? 0), 0);
  const overallPercentage = totalMax > 0 ? Math.round((totalObtained / totalMax) * 100) : 0;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-bold tracking-tight">Academic Results</h2>
        <p className="text-sm text-muted-foreground">
          Subject-wise marks and evaluation reports for your examinations.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-xs font-medium text-muted-foreground">Overall Score</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              {totalObtained} <span className="text-sm font-normal text-muted-foreground">/ {totalMax}</span>
            </div>
            <p className="text-xs text-muted-foreground mt-1">Aggregate: {overallPercentage}%</p>
          </CardContent>
        </Card>

        {/* AC 2: When show_rank is enabled, display student's own rank. When disabled, RLS returns 0 rows and this card is hidden */}
        {latestPosition && latestPosition.is_ranked && latestPosition.rank_in_section && (
          <Card className="border-primary/20 bg-primary/5">
            <CardHeader className="pb-2">
              <CardTitle className="text-xs font-medium text-primary">Class Rank</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold text-primary">
                #{latestPosition.rank_in_section}
                {latestPosition.ranked_out_of ? (
                  <span className="text-sm font-normal text-muted-foreground"> / {latestPosition.ranked_out_of}</span>
                ) : null}
              </div>
              <p className="text-xs text-muted-foreground mt-1">
                Section Rank · Term: {Array.isArray(latestPosition.exam_term) ? latestPosition.exam_term[0]?.name : (latestPosition.exam_term as any)?.name ?? 'Current'}
              </p>
            </CardContent>
          </Card>
        )}
      </div>

      {results.length === 0 ? (
        <div className="rounded-lg border bg-card p-12 text-center text-muted-foreground">
          <Award className="mx-auto h-10 w-10 mb-3 opacity-40" />
          <p className="font-medium">No results published yet.</p>
          <p className="text-xs mt-1">Term marks will be displayed here once officially declared.</p>
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border bg-card shadow-sm">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50 text-left">
                <th className="p-3 font-semibold text-muted-foreground">Term</th>
                <th className="p-3 font-semibold text-muted-foreground">Subject</th>
                <th className="p-3 font-semibold text-muted-foreground text-center">Marks Obtained</th>
                <th className="p-3 font-semibold text-muted-foreground text-center">Max Marks</th>
                <th className="p-3 font-semibold text-muted-foreground text-center">Percentage</th>
                <th className="p-3 font-semibold text-muted-foreground text-center">Status</th>
              </tr>
            </thead>
            <tbody>
              {results.map((r) => {
                const term = Array.isArray(r.exam_term) ? r.exam_term[0] : r.exam_term;
                const subject = Array.isArray(r.subject) ? r.subject[0] : r.subject;
                const pct = r.max_marks && r.max_marks > 0 ? Math.round(((r.obtained ?? 0) / r.max_marks) * 100) : 0;
                return (
                  <tr key={r.id} className="border-b last:border-b-0 hover:bg-muted/20">
                    <td className="p-3 font-medium text-muted-foreground">{term?.name ?? '—'}</td>
                    <td className="p-3 font-semibold text-foreground">{subject?.name_en ?? '—'}</td>
                    <td className="p-3 text-center font-bold">{r.obtained}</td>
                    <td className="p-3 text-center text-muted-foreground">{r.max_marks}</td>
                    <td className="p-3 text-center font-medium">{pct}%</td>
                    <td className="p-3 text-center">
                      {r.is_pass ? (
                        <Badge variant="outline" className="border-emerald-300 text-emerald-700 bg-emerald-50 dark:bg-emerald-950/30">
                          <CheckCircle2 className="mr-1 h-3 w-3" /> Pass
                        </Badge>
                      ) : (
                        <Badge variant="destructive">
                          <XCircle className="mr-1 h-3 w-3" /> Fail
                        </Badge>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

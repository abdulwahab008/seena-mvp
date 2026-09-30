import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { AlertCircle, Clock, MessageSquare, ChevronRight, CheckCircle2 } from 'lucide-react';

export default async function StaffTicketsPage() {
  const supabase = await supabaseServer();

  // Query campus tickets via staff RLS
  const { data: tickets } = await supabase
    .from('support_ticket')
    .select(`
      id,
      ticket_no,
      category,
      status,
      subject,
      created_at,
      sla_due_at,
      breached_at,
      resolved_at,
      student:student_id(name_en, gr_number)
    `)
    .order('created_at', { ascending: false });

  const totalCount = tickets?.length ?? 0;
  const openCount = tickets?.filter((t) => t.status === 'open').length ?? 0;
  const breachedCount = tickets?.filter((t) => !!t.breached_at && t.status !== 'resolved').length ?? 0;

  return (
    <div className="space-y-6 p-6">
      <div className="flex flex-col gap-2">
        <h1 className="text-2xl font-bold tracking-tight">Support Desk & Complaints</h1>
        <p className="text-sm text-muted-foreground">
          Manage parent inquiries, transport issues, fee queries, and maintain SLA compliance.
        </p>
      </div>

      <div className="grid gap-4 grid-cols-1 sm:grid-cols-3">
        <Card>
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs">Total Tickets</CardDescription>
            <CardTitle className="text-2xl">{totalCount}</CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs">Awaiting Reply</CardDescription>
            <CardTitle className="text-2xl text-amber-600">{openCount}</CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader className="p-4 pb-2">
            <CardDescription className="text-xs">SLA Breached</CardDescription>
            <CardTitle className="text-2xl text-destructive">{breachedCount}</CardTitle>
          </CardHeader>
        </Card>
      </div>

      {!tickets || tickets.length === 0 ? (
        <Card className="border-dashed py-12 text-center">
          <CardContent className="space-y-3">
            <CheckCircle2 className="mx-auto h-10 w-10 text-emerald-500/80" />
            <div className="text-base font-medium">All caught up! No active tickets</div>
            <p className="text-sm text-muted-foreground max-w-sm mx-auto">
              Any complaint or query submitted by parents will appear here with automated SLA tracking.
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {tickets.map((t) => {
            const isBreached = !!t.breached_at && t.status !== 'resolved';
            return (
              <Link key={t.id} href={`/staff/tickets/${t.id}`}>
                <Card className="hover:border-primary/50 transition-colors cursor-pointer">
                  <CardContent className="p-4 sm:p-5 flex items-center justify-between gap-4">
                    <div className="space-y-1.5 min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-mono text-xs font-semibold px-2 py-0.5 rounded bg-muted">
                          {t.ticket_no}
                        </span>
                        <Badge variant="outline" className="capitalize text-xs">
                          {t.category}
                        </Badge>
                        <Badge
                          variant={
                            t.status === 'resolved'
                              ? 'default'
                              : t.status === 'in_progress'
                              ? 'info'
                              : 'outline'
                          }
                          className="capitalize text-xs"
                        >
                          {t.status.replace('_', ' ')}
                        </Badge>
                        {isBreached && (
                          <Badge variant="destructive" className="text-xs gap-1">
                            <AlertCircle className="h-3 w-3" />
                            SLA Breached
                          </Badge>
                        )}
                      </div>

                      <h3 className="font-semibold text-base text-foreground truncate">
                        {t.subject}
                      </h3>

                      <div className="flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
                        {t.student && (
                          <span>
                            Student: {(t.student as any).name_en} ({(t.student as any).gr_number})
                          </span>
                        )}
                        <span>
                          Created: {new Date(t.created_at).toLocaleString()}
                        </span>
                        {t.status !== 'resolved' && (
                          <span className="flex items-center gap-1 font-medium">
                            <Clock className="h-3 w-3" />
                            SLA Target: {new Date(t.sla_due_at).toLocaleString()}
                          </span>
                        )}
                      </div>
                    </div>

                    <ChevronRight className="h-5 w-5 text-muted-foreground shrink-0" />
                  </CardContent>
                </Card>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}

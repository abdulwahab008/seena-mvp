import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { NewTicketDialog } from './new-ticket-dialog';
import { AlertCircle, CheckCircle2, Clock, MessageSquare, ChevronRight } from 'lucide-react';

export default async function PortalTicketsPage() {
  const supabase = await supabaseServer();

  // Get current guardian's students to allow selecting child
  const { data: students } = await supabase
    .from('student')
    .select('id, name_en, gr_number, campus_id')
    .order('name_en');

  // Fallback campus ID
  const campusId = students?.[0]?.campus_id || '99999999-9999-9999-9999-999999999999';

  // Query tickets created by or visible to this parent via RLS
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

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold tracking-tight">Support & Complaints Desk</h2>
          <p className="text-sm text-muted-foreground">
            Track inquiries, transport complaints, and official school office communication.
          </p>
        </div>
        <NewTicketDialog campusId={campusId} students={students || []} />
      </div>

      {!tickets || tickets.length === 0 ? (
        <Card className="border-dashed py-12 text-center">
          <CardContent className="space-y-3">
            <MessageSquare className="mx-auto h-10 w-10 text-muted-foreground/60" />
            <div className="text-base font-medium">No complaints or tickets raised</div>
            <p className="text-sm text-muted-foreground max-w-sm mx-auto">
              If you have any queries about van routes, fee challans, or school policies, submit a ticket above.
            </p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {tickets.map((t) => {
            const isBreached = !!t.breached_at && t.status !== 'resolved';
            return (
              <Link key={t.id} href={`/portal/tickets/${t.id}`}>
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
                            Overdue
                          </Badge>
                        )}
                      </div>

                      <h3 className="font-semibold text-base text-foreground truncate">
                        {t.subject}
                      </h3>

                      <div className="flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
                        {t.student && (
                          <span>
                            Child: {(t.student as any).name_en} ({(t.student as any).gr_number})
                          </span>
                        )}
                        <span>
                          Raised: {new Date(t.created_at).toLocaleDateString()}
                        </span>
                        {t.status !== 'resolved' && (
                          <span className="flex items-center gap-1">
                            <Clock className="h-3 w-3" />
                            SLA Due: {new Date(t.sla_due_at).toLocaleDateString()}
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

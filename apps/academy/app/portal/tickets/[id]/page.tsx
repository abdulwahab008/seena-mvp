import { notFound } from 'next/navigation';
import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { TicketThreadClient } from './ticket-thread-client';
import { ArrowLeft, Clock, AlertCircle, User, ShieldCheck } from 'lucide-react';

export default async function PortalTicketDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await supabaseServer();

  // Query ticket
  const { data: ticket } = await supabase
    .from('support_ticket')
    .select(`
      id,
      ticket_no,
      category,
      status,
      subject,
      description,
      created_at,
      sla_due_at,
      breached_at,
      resolved_at,
      student:student_id(name_en, gr_number)
    `)
    .eq('id', id)
    .single();

  if (!ticket) {
    notFound();
  }

  // Query public messages for this ticket (RLS already hides internal notes from parents)
  const { data: messages } = await supabase
    .from('ticket_message')
    .select(`
      id,
      author_id,
      body,
      is_internal,
      created_at
    `)
    .eq('ticket_id', id)
    .order('created_at', { ascending: true });

  const isBreached = !!ticket.breached_at && ticket.status !== 'resolved';

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-2">
        <Link
          href="/portal/tickets"
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to Tickets
        </Link>
      </div>

      <Card>
        <CardHeader className="space-y-3 pb-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-mono text-sm font-bold px-2.5 py-1 rounded bg-muted">
                {ticket.ticket_no}
              </span>
              <Badge variant="outline" className="capitalize">
                {ticket.category}
              </Badge>
              <Badge
                variant={
                  ticket.status === 'resolved'
                    ? 'default'
                    : ticket.status === 'in_progress'
                    ? 'info'
                    : 'outline'
                }
                className="capitalize"
              >
                {ticket.status.replace('_', ' ')}
              </Badge>
              {isBreached && (
                <Badge variant="destructive" className="gap-1">
                  <AlertCircle className="h-3.5 w-3.5" />
                  SLA Overdue
                </Badge>
              )}
            </div>

            <div className="text-xs text-muted-foreground flex items-center gap-1">
              <Clock className="h-3.5 w-3.5" />
              SLA Due: {new Date(ticket.sla_due_at).toLocaleString()}
            </div>
          </div>

          <CardTitle className="text-xl">{ticket.subject}</CardTitle>
          {ticket.student && (
            <CardDescription>
              Regarding: {(ticket.student as any).name_en} ({(ticket.student as any).gr_number})
            </CardDescription>
          )}
        </CardHeader>

        <CardContent className="space-y-6">
          {/* Thread messages */}
          <div className="space-y-4">
            {messages && messages.map((m, idx) => {
              const isInitial = idx === 0;
              return (
                <div
                  key={m.id}
                  className="rounded-lg border bg-card p-4 space-y-2 shadow-xs"
                >
                  <div className="flex items-center justify-between text-xs text-muted-foreground">
                    <span className="flex items-center gap-1.5 font-medium text-foreground">
                      <User className="h-3.5 w-3.5" />
                      {isInitial ? 'Original Query' : 'Reply'}
                    </span>
                    <span>{new Date(m.created_at).toLocaleString()}</span>
                  </div>
                  <p className="text-sm whitespace-pre-wrap leading-relaxed text-foreground/90">
                    {m.body}
                  </p>
                </div>
              );
            })}
          </div>

          {/* Reply box and 7-day reopen action */}
          <TicketThreadClient
            ticketId={ticket.id}
            status={ticket.status}
            resolvedAt={ticket.resolved_at}
          />
        </CardContent>
      </Card>
    </div>
  );
}

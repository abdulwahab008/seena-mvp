import { notFound } from 'next/navigation';
import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { StaffTicketResponseClient } from './staff-ticket-response-client';
import { ArrowLeft, Clock, AlertCircle, User, Lock } from 'lucide-react';

export default async function StaffTicketDetailPage({
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
      first_staff_reply_at,
      student:student_id(name_en, gr_number)
    `)
    .eq('id', id)
    .single();

  if (!ticket) {
    notFound();
  }

  // Query messages including internal notes (staff RLS allows internal notes)
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
    <div className="space-y-6 p-6 max-w-4xl mx-auto">
      <div className="flex items-center gap-2">
        <Link
          href="/staff/tickets"
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to Ticket Desk
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
                  SLA Breached
                </Badge>
              )}
            </div>

            <div className="text-xs text-muted-foreground flex items-center gap-1 font-mono">
              <Clock className="h-3.5 w-3.5" />
              SLA Target: {new Date(ticket.sla_due_at).toLocaleString()}
            </div>
          </div>

          <CardTitle className="text-xl">{ticket.subject}</CardTitle>
          {ticket.student && (
            <CardDescription>
              Regarding Student: {(ticket.student as any).name_en} ({(ticket.student as any).gr_number})
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
                  className={`rounded-lg border p-4 space-y-2 shadow-xs ${
                    m.is_internal
                      ? 'border-amber-300 bg-amber-50/40'
                      : 'bg-card'
                  }`}
                >
                  <div className="flex items-center justify-between text-xs text-muted-foreground">
                    <span className="flex items-center gap-1.5 font-medium text-foreground">
                      {m.is_internal ? (
                        <>
                          <Lock className="h-3.5 w-3.5 text-amber-600" />
                          <span className="text-amber-800 font-semibold">Staff Internal Note</span>
                        </>
                      ) : (
                        <>
                          <User className="h-3.5 w-3.5" />
                          <span>{isInitial ? 'Initial Parent Query' : 'Public Message'}</span>
                        </>
                      )}
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

          {/* Staff response and resolve actions */}
          <StaffTicketResponseClient
            ticketId={ticket.id}
            status={ticket.status}
          />
        </CardContent>
      </Card>
    </div>
  );
}

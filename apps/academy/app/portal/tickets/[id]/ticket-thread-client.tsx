'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { addTicketMessageAction, reopenTicketAction } from '../actions';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { AlertCircle, RotateCcw, Send } from 'lucide-react';

interface TicketThreadClientProps {
  ticketId: string;
  status: string;
  resolvedAt: string | null;
}

export function TicketThreadClient({ ticketId, status, resolvedAt }: TicketThreadClientProps) {
  const router = useRouter();
  const [replyBody, setReplyBody] = useState('');
  const [replyLoading, setReplyLoading] = useState(false);
  const [replyError, setReplyError] = useState<string | null>(null);

  const [reopenReason, setReopenReason] = useState('');
  const [reopenLoading, setReopenLoading] = useState(false);
  const [reopenError, setReopenError] = useState<string | null>(null);
  const [showReopenForm, setShowReopenForm] = useState(false);

  // Check if 7 days have passed since resolution
  const isResolved = status === 'resolved';
  const resolvedTime = resolvedAt ? new Date(resolvedAt).getTime() : 0;
  const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
  const canReopen = isResolved && Date.now() - resolvedTime <= sevenDaysMs;

  async function handleSendReply(e: React.FormEvent) {
    e.preventDefault();
    if (!replyBody.trim()) return;

    setReplyLoading(true);
    setReplyError(null);

    const formData = new FormData();
    formData.append('ticket_id', ticketId);
    formData.append('body', replyBody.trim());
    formData.append('is_internal', 'false');

    const res = await addTicketMessageAction(formData);
    setReplyLoading(false);

    if (res.error) {
      setReplyError(res.error);
    } else {
      setReplyBody('');
      router.refresh();
    }
  }

  async function handleReopen(e: React.FormEvent) {
    e.preventDefault();
    if (!reopenReason.trim()) return;

    setReopenLoading(true);
    setReopenError(null);

    const formData = new FormData();
    formData.append('ticket_id', ticketId);
    formData.append('reason', reopenReason.trim());

    const res = await reopenTicketAction(formData);
    setReopenLoading(false);

    if (res.error) {
      setReopenError(res.error);
    } else {
      setShowReopenForm(false);
      setReopenReason('');
      router.refresh();
    }
  }

  return (
    <div className="space-y-4 pt-4 border-t">
      {isResolved ? (
        <div className="rounded-lg border bg-muted/30 p-4 space-y-3">
          <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
            <div>
              <p className="text-sm font-medium">This ticket has been marked resolved.</p>
              <p className="text-xs text-muted-foreground">
                {canReopen
                  ? 'If your issue is not resolved, you may reopen this ticket within 7 days of closure.'
                  : 'This ticket was closed over 7 days ago and cannot be reopened.'}
              </p>
            </div>
            {canReopen && !showReopenForm && (
              <Button
                variant="outline"
                size="sm"
                className="gap-1.5 shrink-0"
                onClick={() => setShowReopenForm(true)}
              >
                <RotateCcw className="h-4 w-4" />
                Reopen Ticket
              </Button>
            )}
          </div>

          {showReopenForm && (
            <form onSubmit={handleReopen} className="space-y-3 pt-2 border-t">
              {reopenError && (
                <div className="flex items-center gap-2 rounded bg-destructive/15 p-2 text-xs text-destructive">
                  <AlertCircle className="h-4 w-4 shrink-0" />
                  <span>{reopenError}</span>
                </div>
              )}
              <Textarea
                placeholder="State the reason why you are reopening this ticket..."
                rows={2}
                value={reopenReason}
                onChange={(e) => setReopenReason(e.target.value)}
                required
              />
              <div className="flex justify-end gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => setShowReopenForm(false)}
                  disabled={reopenLoading}
                >
                  Cancel
                </Button>
                <Button type="submit" size="sm" disabled={reopenLoading}>
                  {reopenLoading ? 'Reopening...' : 'Confirm Reopen'}
                </Button>
              </div>
            </form>
          )}
        </div>
      ) : (
        <form onSubmit={handleSendReply} className="space-y-3">
          {replyError && (
            <div className="flex items-center gap-2 rounded bg-destructive/15 p-2 text-xs text-destructive">
              <AlertCircle className="h-4 w-4 shrink-0" />
              <span>{replyError}</span>
            </div>
          )}
          <Textarea
            placeholder="Write a message or reply to the school office..."
            rows={3}
            value={replyBody}
            onChange={(e) => setReplyBody(e.target.value)}
            required
          />
          <div className="flex justify-end">
            <Button type="submit" size="sm" className="gap-2" disabled={replyLoading}>
              <Send className="h-4 w-4" />
              {replyLoading ? 'Sending...' : 'Send Reply'}
            </Button>
          </div>
        </form>
      )}
    </div>
  );
}

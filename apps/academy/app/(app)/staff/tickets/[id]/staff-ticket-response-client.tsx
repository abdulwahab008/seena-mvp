'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { addTicketMessageAction, resolveTicketAction } from '@/app/portal/tickets/actions';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Checkbox } from '@/components/ui/checkbox';
import { Modal } from '@/components/ui/modal';
import { AlertCircle, CheckCircle2, Lock, Send } from 'lucide-react';

interface StaffTicketResponseClientProps {
  ticketId: string;
  status: string;
}

export function StaffTicketResponseClient({ ticketId, status }: StaffTicketResponseClientProps) {
  const router = useRouter();

  // Reply form state
  const [replyBody, setReplyBody] = useState('');
  const [isInternal, setIsInternal] = useState(false);
  const [replyLoading, setReplyLoading] = useState(false);
  const [replyError, setReplyError] = useState<string | null>(null);

  // Resolve modal state
  const [resolveOpen, setResolveOpen] = useState(false);
  const [resolutionNote, setResolutionNote] = useState('');
  const [resolveLoading, setResolveLoading] = useState(false);
  const [resolveError, setResolveError] = useState<string | null>(null);

  const isResolved = status === 'resolved';

  async function handleSendReply(e: React.FormEvent) {
    e.preventDefault();
    if (!replyBody.trim()) return;

    setReplyLoading(true);
    setReplyError(null);

    const formData = new FormData();
    formData.append('ticket_id', ticketId);
    formData.append('body', replyBody.trim());
    formData.append('is_internal', isInternal ? 'true' : 'false');

    const res = await addTicketMessageAction(formData);
    setReplyLoading(false);

    if (res.error) {
      setReplyError(res.error);
    } else {
      setReplyBody('');
      setIsInternal(false);
      router.refresh();
    }
  }

  async function handleResolve(e: React.FormEvent) {
    e.preventDefault();
    setResolveLoading(true);
    setResolveError(null);

    const formData = new FormData();
    formData.append('ticket_id', ticketId);
    formData.append('resolution_note', resolutionNote.trim());

    const res = await resolveTicketAction(formData);
    setResolveLoading(false);

    if (res.error) {
      setResolveError(res.error);
    } else {
      setResolveOpen(false);
      setResolutionNote('');
      router.refresh();
    }
  }

  return (
    <div className="space-y-4 pt-4 border-t">
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold">Post a Reply or Internal Note</h4>
        {!isResolved && (
          <Button
            variant="outline"
            size="sm"
            className="gap-1.5 text-emerald-600 border-emerald-300 hover:bg-emerald-50"
            onClick={() => setResolveOpen(true)}
          >
            <CheckCircle2 className="h-4 w-4" />
            Resolve Ticket
          </Button>
        )}
      </div>

      <Modal
        open={resolveOpen}
        onClose={() => setResolveOpen(false)}
        title="Mark Ticket as Resolved"
        description="Provide an official resolution note for the parent. The parent can reopen this ticket within 7 days if the issue persists."
        size="md"
        footer={
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => setResolveOpen(false)} disabled={resolveLoading}>
              Cancel
            </Button>
            <Button type="submit" form="resolve-ticket-form" disabled={resolveLoading}>
              {resolveLoading ? 'Resolving...' : 'Confirm Resolution'}
            </Button>
          </div>
        }
      >
        <form id="resolve-ticket-form" onSubmit={handleResolve} className="space-y-4">
          {resolveError && (
            <div className="flex items-center gap-2 rounded bg-destructive/15 p-2 text-xs text-destructive">
              <AlertCircle className="h-4 w-4 shrink-0" />
              <span>{resolveError}</span>
            </div>
          )}

          <div className="space-y-2">
            <Label htmlFor="resolutionNote">Resolution Summary</Label>
            <Textarea
              id="resolutionNote"
              placeholder="e.g. Route 4 driver was given written warning, departure time adjusted to 07:15 AM."
              rows={3}
              value={resolutionNote}
              onChange={(e) => setResolutionNote(e.target.value)}
              required
            />
          </div>
        </form>
      </Modal>

      <form onSubmit={handleSendReply} className="space-y-3">
        {replyError && (
          <div className="flex items-center gap-2 rounded bg-destructive/15 p-2 text-xs text-destructive">
            <AlertCircle className="h-4 w-4 shrink-0" />
            <span>{replyError}</span>
          </div>
        )}

        <Textarea
          placeholder={
            isInternal
              ? 'Write an internal staff note (visible ONLY to school staff, hidden from parents)...'
              : 'Write an official reply to the parent...'
          }
          rows={3}
          value={replyBody}
          onChange={(e) => setReplyBody(e.target.value)}
          required
          className={isInternal ? 'border-amber-400 bg-amber-50/30' : ''}
        />

        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center space-x-2">
            <Checkbox
              id="internalNote"
              checked={isInternal}
              onCheckedChange={(checked) => setIsInternal(!!checked)}
            />
            <Label
              htmlFor="internalNote"
              className="text-xs font-normal cursor-pointer flex items-center gap-1 text-muted-foreground"
            >
              <Lock className="h-3 w-3 text-amber-600" />
              Staff Internal Note (Hidden from parent)
            </Label>
          </div>

          <Button type="submit" size="sm" className="gap-2" disabled={replyLoading}>
            <Send className="h-4 w-4" />
            {replyLoading ? 'Posting...' : isInternal ? 'Save Internal Note' : 'Send Public Reply'}
          </Button>
        </div>
      </form>
    </div>
  );
}

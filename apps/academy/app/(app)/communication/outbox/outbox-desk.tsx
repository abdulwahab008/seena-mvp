'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import {
  Send,
  RefreshCw,
  AlertTriangle,
  CheckCircle2,
  Clock,
  Radio,
  FileText,
  Search,
  Plus,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Modal } from '@/components/ui/modal';
import {
  OutboxMessageRow,
  OutboxStats,
  createOutboundMessage,
  processOutboxBatch,
  resolveUnknownOutboxAttempt,
} from '../actions';

type Campus = { id: string; code: string; name: string };

export function OutboxDesk({
  initialMessages,
  initialStats,
  campuses,
  selectedCampusId,
}: {
  initialMessages: OutboxMessageRow[];
  initialStats: OutboxStats;
  campuses: Campus[];
  selectedCampusId: string | null;
}) {
  const router = useRouter();
  const [messages, setMessages] = React.useState<OutboxMessageRow[]>(initialMessages);
  const [stats, setStats] = React.useState<OutboxStats>(initialStats);
  const [activeTab, setActiveTab] = React.useState<string>('all');
  const [search, setSearch] = React.useState<string>('');
  const [selectedMessage, setSelectedMessage] = React.useState<OutboxMessageRow | null>(null);

  // Compose Modal State
  const [isComposeOpen, setIsComposeOpen] = React.useState<boolean>(false);
  const [composeCampus, setComposeCampus] = React.useState<string>(selectedCampusId || campuses[0]?.id || '');
  const [composeChannel, setComposeChannel] = React.useState<'sms' | 'whatsapp' | 'email' | 'push'>('sms');
  const [composePhone, setComposePhone] = React.useState<string>('+923001234567');
  const [composeBody, setComposeBody] = React.useState<string>('');
  const [isSubmitting, setIsSubmitting] = React.useState<boolean>(false);

  // Resolve Modal State
  const [resolveAttemptId, setResolveAttemptId] = React.useState<string | null>(null);
  const [resolveStatus, setResolveStatus] = React.useState<'delivered' | 'sent' | 'failed'>('delivered');
  const [resolveRef, setResolveRef] = React.useState<string>('');
  const [isResolving, setIsResolving] = React.useState<boolean>(false);

  // Batch Processing
  const [isDispatching, setIsDispatching] = React.useState<boolean>(false);

  React.useEffect(() => {
    setMessages(initialMessages);
  }, [initialMessages]);

  React.useEffect(() => {
    setStats(initialStats);
  }, [initialStats]);

  const filteredMessages = messages.filter((m) => {
    if (activeTab !== 'all' && m.status !== activeTab) return false;
    if (search.trim()) {
      const q = search.toLowerCase();
      const matchPhone = m.recipient_phone?.toLowerCase().includes(q);
      const matchBody = m.body?.toLowerCase().includes(q);
      const matchIdem = m.idempotency_key?.toLowerCase().includes(q);
      if (!matchPhone && !matchBody && !matchIdem) return false;
    }
    return true;
  });

  const handleCampusChange = (campusId: string) => {
    const url = new URL(window.location.href);
    if (campusId) {
      url.searchParams.set('campus', campusId);
    } else {
      url.searchParams.delete('campus');
    }
    router.push(url.toString());
  };

  const handleCompose = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!composeBody.trim()) return;
    setIsSubmitting(true);
    const res = await createOutboundMessage({
      campusId: composeCampus,
      channel: composeChannel,
      recipientPhone: composePhone,
      body: composeBody,
    });
    setIsSubmitting(false);
    if (res.success) {
      setIsComposeOpen(false);
      if (res.messageId) {
        setMessages((prev) => [
          {
            id: res.messageId!,
            tenant_id: '',
            campus_id: composeCampus,
            batch_id: null,
            recipient_type: 'guardian',
            recipient_id: null,
            recipient_phone: composePhone,
            recipient_email: null,
            channel: composeChannel,
            sender_id: 'SEENA',
            subject: null,
            body: composeBody,
            status: 'queued',
            scheduled_at: new Date().toISOString(),
            claimed_at: null,
            claimed_by: null,
            idempotency_key: null,
            metadata: {},
            created_at: new Date().toISOString(),
            attempts: [],
          },
          ...prev,
        ]);
        setStats((prev) => ({ ...prev, queued: prev.queued + 1, total: prev.total + 1 }));
      }
      setComposeBody('');
      router.refresh();
    } else {
      alert(`Error creating message: ${res.error}`);
    }
  };

  const handleDispatchBatch = async () => {
    setIsDispatching(true);
    const workerId = crypto.randomUUID();
    const res = await processOutboxBatch(workerId, 25);
    setIsDispatching(false);
    if (res.success) {
      router.refresh();
    } else {
      alert(`Dispatch error: ${res.error}`);
    }
  };

  const handleResolveUnknown = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!resolveAttemptId || !resolveRef) return;
    setIsResolving(true);
    const res = await resolveUnknownOutboxAttempt(resolveAttemptId, resolveStatus, resolveRef);
    setIsResolving(false);
    if (res.success) {
      setResolveAttemptId(null);
      setSelectedMessage(null);
      router.refresh();
    } else {
      alert(`Resolution error: ${res.error}`);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between border-b pb-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">
            Unified Outbound Message Outbox
          </h1>
          <p className="text-sm text-muted-foreground">
            FR-M01: Auditable multi-channel message queue with concurrent batch locking and aggregator timeout protection.
          </p>
        </div>
        <div className="flex items-center gap-3">
          <select
            value={selectedCampusId || ''}
            onChange={(e) => handleCampusChange(e.target.value)}
            className="rounded-md border border-input bg-background px-3 py-1.5 text-sm ring-offset-background"
          >
            <option value="">All Campuses</option>
            {campuses.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name} ({c.code})
              </option>
            ))}
          </select>

          <Button
            variant="outline"
            size="sm"
            onClick={handleDispatchBatch}
            disabled={isDispatching}
            className="gap-1.5"
          >
            <RefreshCw className={`h-4 w-4 ${isDispatching ? 'animate-spin' : ''}`} />
            Claim &amp; Dispatch Batch
          </Button>

          <Button
            size="sm"
            onClick={() => setIsComposeOpen(true)}
            className="gap-1.5"
          >
            <Plus className="h-4 w-4" />
            New Message
          </Button>
        </div>
      </div>

      {/* Metrics Row */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6">
        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase">Queued</span>
            <Clock className="h-4 w-4 text-blue-500" />
          </div>
          <p className="mt-2 text-2xl font-bold text-foreground">{stats.queued}</p>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase">Claimed</span>
            <Radio className="h-4 w-4 text-amber-500" />
          </div>
          <p className="mt-2 text-2xl font-bold text-foreground">{stats.claimed}</p>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase">Sending</span>
            <Send className="h-4 w-4 text-indigo-500" />
          </div>
          <p className="mt-2 text-2xl font-bold text-foreground">{stats.sending}</p>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase">Delivered</span>
            <CheckCircle2 className="h-4 w-4 text-emerald-500" />
          </div>
          <p className="mt-2 text-2xl font-bold text-foreground">{stats.delivered}</p>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase">Unknown (Timeout)</span>
            <AlertTriangle className="h-4 w-4 text-amber-600" />
          </div>
          <p className="mt-2 text-2xl font-bold text-foreground">{stats.unknown}</p>
        </div>

        <div className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="flex items-center justify-between text-muted-foreground">
            <span className="text-xs font-medium uppercase">Failed</span>
            <AlertTriangle className="h-4 w-4 text-red-500" />
          </div>
          <p className="mt-2 text-2xl font-bold text-foreground">{stats.failed}</p>
        </div>
      </div>

      {/* Tabs & Search */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-wrap gap-1 rounded-lg border bg-muted/40 p-1">
          {['all', 'queued', 'claimed', 'sending', 'delivered', 'unknown', 'failed'].map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`rounded-md px-3 py-1 text-xs font-medium capitalize transition-colors ${
                activeTab === tab
                  ? 'bg-background text-foreground shadow-sm'
                  : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              {tab}
            </button>
          ))}
        </div>

        <div className="relative w-full sm:w-64">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <input
            type="text"
            placeholder="Search phone, text, or key..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full rounded-md border border-input bg-background pl-8 pr-3 py-1.5 text-sm ring-offset-background"
          />
        </div>
      </div>

      {/* Table */}
      <div className="rounded-md border bg-card shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b bg-muted/30 text-xs font-semibold text-muted-foreground uppercase">
              <tr>
                <th className="px-4 py-3">Scheduled / Created</th>
                <th className="px-4 py-3">Channel</th>
                <th className="px-4 py-3">Recipient</th>
                <th className="px-4 py-3">Message Body</th>
                <th className="px-4 py-3">Status</th>
                <th className="px-4 py-3">Attempts</th>
                <th className="px-4 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {filteredMessages.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-muted-foreground">
                    No messages found matching current filter.
                  </td>
                </tr>
              ) : (
                filteredMessages.map((m) => (
                  <tr key={m.id} className="hover:bg-muted/20">
                    <td className="px-4 py-3 whitespace-nowrap text-xs text-muted-foreground">
                      {new Date(m.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
                      <div className="text-[10px] text-muted-foreground/70">
                        {new Date(m.created_at).toLocaleDateString()}
                      </div>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold uppercase bg-slate-100 dark:bg-slate-800 text-slate-800 dark:text-slate-200">
                        {m.channel}
                      </span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap font-medium text-foreground">
                      {m.recipient_phone || m.recipient_email || '—'}
                      <div className="text-xs text-muted-foreground capitalize">
                        {m.recipient_type}
                      </div>
                    </td>
                    <td className="px-4 py-3 max-w-xs truncate text-muted-foreground" title={m.body}>
                      {m.body}
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap">
                      <span
                        className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold capitalize ${
                          m.status === 'delivered'
                            ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950/60 dark:text-emerald-400'
                            : m.status === 'queued'
                            ? 'bg-blue-100 text-blue-800 dark:bg-blue-950/60 dark:text-blue-400'
                            : m.status === 'claimed'
                            ? 'bg-amber-100 text-amber-800 dark:bg-amber-950/60 dark:text-amber-400'
                            : m.status === 'unknown'
                            ? 'bg-orange-100 text-orange-800 dark:bg-orange-950/60 dark:text-orange-400'
                            : m.status === 'failed'
                            ? 'bg-rose-100 text-rose-800 dark:bg-rose-950/60 dark:text-rose-400'
                            : 'bg-slate-100 text-slate-800 dark:bg-slate-800 dark:text-slate-300'
                        }`}
                      >
                        {m.status}
                      </span>
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-xs text-muted-foreground">
                      {m.attempts?.length || 0} attempt(s)
                    </td>
                    <td className="px-4 py-3 whitespace-nowrap text-right">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setSelectedMessage(m)}
                        className="h-8 px-2 text-xs"
                      >
                        Inspect
                      </Button>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Inspect Message Drawer / Modal */}
      {selectedMessage && (
        <Modal
          open={!!selectedMessage}
          onClose={() => setSelectedMessage(null)}
          title="Message Outbox Details"
          size="lg"
        >
          <div className="space-y-4 text-sm">
            <div className="grid grid-cols-2 gap-4 rounded-md bg-muted/40 p-3">
              <div>
                <span className="text-xs text-muted-foreground">Message ID</span>
                <p className="font-mono text-xs text-foreground">{selectedMessage.id}</p>
              </div>
              <div>
                <span className="text-xs text-muted-foreground">Idempotency Key</span>
                <p className="font-mono text-xs text-foreground">{selectedMessage.idempotency_key || 'None'}</p>
              </div>
              <div>
                <span className="text-xs text-muted-foreground">Recipient</span>
                <p className="font-medium text-foreground">{selectedMessage.recipient_phone || selectedMessage.recipient_email}</p>
              </div>
              <div>
                <span className="text-xs text-muted-foreground">Channel / Status</span>
                <p className="font-medium capitalize text-foreground">{selectedMessage.channel} • {selectedMessage.status}</p>
              </div>
            </div>

            <div>
              <span className="text-xs font-medium text-muted-foreground">Message Body</span>
              <div className="mt-1 rounded-md border p-3 font-mono text-xs text-foreground bg-background whitespace-pre-wrap">
                {selectedMessage.body}
              </div>
            </div>

            <div>
              <span className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                Dispatch Attempts ({selectedMessage.attempts?.length || 0})
              </span>
              <div className="mt-2 space-y-2">
                {(!selectedMessage.attempts || selectedMessage.attempts.length === 0) ? (
                  <p className="text-xs text-muted-foreground italic">No dispatch attempts recorded yet.</p>
                ) : (
                  selectedMessage.attempts.map((att) => (
                    <div key={att.id} className="rounded border p-3 bg-card">
                      <div className="flex items-center justify-between">
                        <span className="font-medium text-xs">
                          Attempt #{att.attempt_number} • Status: <span className="uppercase">{att.status}</span>
                        </span>
                        <span className="text-[11px] text-muted-foreground">
                          {new Date(att.dispatched_at).toLocaleTimeString()}
                        </span>
                      </div>
                      {att.provider_ref && (
                        <div className="mt-1 text-xs">
                          <span className="text-muted-foreground">Provider Ref: </span>
                          <span className="font-mono">{att.provider_ref}</span>
                        </div>
                      )}
                      {att.error_code && (
                        <div className="mt-1 text-xs text-rose-600 dark:text-rose-400">
                          {att.error_code}: {att.error_message}
                        </div>
                      )}
                      {att.status === 'timeout' || att.status === 'unknown' ? (
                        <div className="mt-2">
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => {
                              setResolveAttemptId(att.id);
                              setResolveRef(att.provider_ref || 'JAZZ-DLR-AUTO-01');
                            }}
                            className="h-7 text-xs text-amber-700 dark:text-amber-400 border-amber-300"
                          >
                            Resolve Status via Aggregator Lookup
                          </Button>
                        </div>
                      ) : null}
                    </div>
                  ))
                )}
              </div>
            </div>
          </div>
        </Modal>
      )}

      {/* Compose Modal */}
      <Modal
        open={isComposeOpen}
        onClose={() => setIsComposeOpen(false)}
        title="Compose Outbound Message"
        size="md"
      >
        <form onSubmit={handleCompose} className="space-y-4 text-sm">
          <div>
            <label className="block text-xs font-medium text-muted-foreground mb-1">Campus</label>
            <select
              value={composeCampus}
              onChange={(e) => setComposeCampus(e.target.value)}
              className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm"
              required
            >
              {campuses.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name} ({c.code})
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">Channel</label>
              <select
                value={composeChannel}
                onChange={(e) => setComposeChannel(e.target.value as any)}
                className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm"
              >
                <option value="sms">SMS</option>
                <option value="whatsapp">WhatsApp</option>
                <option value="email">Email</option>
                <option value="push">Push</option>
              </select>
            </div>
            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">Recipient Phone</label>
              <input
                type="text"
                value={composePhone}
                onChange={(e) => setComposePhone(e.target.value)}
                placeholder="+923001234567"
                className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm"
                required
              />
            </div>
          </div>

          <div>
            <label className="block text-xs font-medium text-muted-foreground mb-1">Body</label>
            <textarea
              rows={4}
              value={composeBody}
              onChange={(e) => setComposeBody(e.target.value)}
              placeholder="Enter message body or notification text..."
              className="w-full rounded-md border border-input bg-background p-3 text-sm"
              required
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => setIsComposeOpen(false)}
            >
              Cancel
            </Button>
            <Button type="submit" size="sm" disabled={isSubmitting}>
              {isSubmitting ? 'Enqueuing...' : 'Queue Message'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* Resolve Timeout Modal */}
      {resolveAttemptId && (
        <Modal
          open={!!resolveAttemptId}
          onClose={() => setResolveAttemptId(null)}
          title="Resolve Unknown Aggregator Attempt"
          size="sm"
        >
          <form onSubmit={handleResolveUnknown} className="space-y-4 text-sm">
            <p className="text-xs text-muted-foreground">
              Pakistani SMS aggregators occasionally return HTTP 504 Gateway Timeout while still delivering the message.
              Use this to record provider reference verification without causing duplicate SMS sends.
            </p>

            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">Provider Message Ref</label>
              <input
                type="text"
                value={resolveRef}
                onChange={(e) => setResolveRef(e.target.value)}
                placeholder="e.g. JAZZ-DLR-998811"
                className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm font-mono"
                required
              />
            </div>

            <div>
              <label className="block text-xs font-medium text-muted-foreground mb-1">Verified Status</label>
              <select
                value={resolveStatus}
                onChange={(e) => setResolveStatus(e.target.value as any)}
                className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm"
              >
                <option value="delivered">Delivered</option>
                <option value="sent">Sent (Pending DLR)</option>
                <option value="failed">Failed / Undelivered</option>
              </select>
            </div>

            <div className="flex justify-end gap-2 pt-2">
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => setResolveAttemptId(null)}
              >
                Cancel
              </Button>
              <Button type="submit" size="sm" disabled={isResolving}>
                {isResolving ? 'Resolving...' : 'Confirm Resolution'}
              </Button>
            </div>
          </form>
        </Modal>
      )}
    </div>
  );
}

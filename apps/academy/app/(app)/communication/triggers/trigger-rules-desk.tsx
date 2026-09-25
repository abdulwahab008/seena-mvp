'use client';

import React, { useState, useTransition, useEffect } from 'react';
import {
  Zap,
  Bell,
  Calendar,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Play,
  Plus,
  RefreshCw,
  Power,
  Trash2,
  ShieldCheck,
  Send,
  Layers,
  Sparkles,
} from 'lucide-react';
import {
  TriggerRulesData,
  createTriggerRuleAction,
  toggleTriggerRuleAction,
  deleteTriggerRuleAction,
  runDateBasedEvaluationAction,
  processPendingFiresAction,
  TriggerEventType,
} from './actions';

interface Props {
  initialData: TriggerRulesData;
}

export function TriggerRulesDesk({ initialData }: Props) {
  const [data, setData] = useState<TriggerRulesData>(initialData);
  const [activeTab, setActiveTab] = useState<'rules' | 'fires' | 'simulate'>('rules');
  const [isPending, startTransition] = useTransition();

  // Dialog State
  const [isCreateOpen, setIsCreateOpen] = useState(false);

  // Form State
  const [ruleName, setRuleName] = useState('');
  const [description, setDescription] = useState('');
  const [eventType, setEventType] = useState<TriggerEventType>('attendance_absent');
  const [channel, setChannel] = useState('sms');
  const [daysOverdueStr, setDaysOverdueStr] = useState('1, 7, 15');
  const [formError, setFormError] = useState<string | null>(null);

  // Simulation State
  const [simRunDate, setSimRunDate] = useState(new Date().toISOString().slice(0, 10));

  // Toast State
  const [toastMessage, setToastMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  useEffect(() => {
    setData(initialData);
  }, [initialData]);

  const showToast = (type: 'success' | 'error', text: string) => {
    setToastMessage({ type, text });
    setTimeout(() => setToastMessage(null), 5000);
  };

  const handleCreateSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setFormError(null);

    if (!ruleName.trim()) {
      setFormError('Rule name is required');
      return;
    }

    let condition: Record<string, any> = {};
    if (eventType === 'fee_challan_overdue') {
      const days = daysOverdueStr
        .split(',')
        .map((s) => parseInt(s.trim(), 10))
        .filter((n) => !isNaN(n));
      condition = { days_overdue: days };
    } else if (eventType === 'attendance_absent') {
      condition = { status: 'absent' };
    }

    startTransition(async () => {
      const res = await createTriggerRuleAction({
        name: ruleName,
        description,
        eventType,
        condition,
        channel,
        isEnabled: true,
      });

      if (!res.ok) {
        setFormError(res.error || 'Failed to create rule');
      } else {
        if (res.data) setData(res.data);
        showToast('success', 'Trigger rule created successfully');
        setIsCreateOpen(false);
        setRuleName('');
        setDescription('');
      }
    });
  };

  const handleToggle = (ruleId: string, currentEnabled: boolean) => {
    startTransition(async () => {
      const res = await toggleTriggerRuleAction(ruleId, !currentEnabled);
      if (!res.ok) {
        showToast('error', res.error || 'Failed to toggle rule');
      } else {
        if (res.data) setData(res.data);
        showToast('success', `Rule ${!currentEnabled ? 'enabled' : 'disabled'} (AC 4: no historical backfill)`);
      }
    });
  };

  const handleDelete = (ruleId: string) => {
    if (!confirm('Are you sure you want to delete this trigger rule?')) return;
    startTransition(async () => {
      const res = await deleteTriggerRuleAction(ruleId);
      if (!res.ok) {
        showToast('error', res.error || 'Failed to delete rule');
      } else {
        if (res.data) setData(res.data);
        showToast('success', 'Trigger rule deleted');
      }
    });
  };

  const handleRunEvaluation = () => {
    startTransition(async () => {
      const res = await runDateBasedEvaluationAction(simRunDate);
      if (!res.ok) {
        showToast('error', res.error || 'Evaluation failed');
      } else {
        if (res.data) setData(res.data);
        const newFires = res.results?.reduce((acc, r) => acc + (r.new_fires_count || 0), 0) || 0;
        const cancelled = res.results?.reduce((acc, r) => acc + (r.cancelled_count || 0), 0) || 0;
        showToast('success', `Overdue evaluation completed: ${newFires} new fires, ${cancelled} cancelled.`);
      }
    });
  };

  const handleProcessFires = () => {
    startTransition(async () => {
      const res = await processPendingFiresAction();
      if (!res.ok) {
        showToast('error', res.error || 'Outbox dispatch failed');
      } else {
        if (res.data) setData(res.data);
        showToast('success', `Enqueued ${res.processedCount || 0} messages into outbox.`);
      }
    });
  };

  return (
    <div className="space-y-6">
      {/* Toast Notification */}
      {toastMessage && (
        <div
          role="status"
          className={`fixed bottom-6 right-6 z-50 flex items-center gap-3 rounded-xl border px-4 py-3 shadow-lg transition-all ${
            toastMessage.type === 'success'
              ? 'border-emerald-500/30 bg-emerald-950/90 text-emerald-200'
              : 'border-rose-500/30 bg-rose-950/90 text-rose-200'
          }`}
        >
          {toastMessage.type === 'success' ? (
            <CheckCircle2 className="h-5 w-5 text-emerald-400" />
          ) : (
            <XCircle className="h-5 w-5 text-rose-400" />
          )}
          <span className="text-sm font-medium">{toastMessage.text}</span>
        </div>
      )}

      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between border-b pb-5">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-amber-500/10 text-amber-400 border border-amber-500/20">
            <Zap className="h-5 w-5" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-foreground">
              Event-Triggered Message Rules
            </h1>
            <p className="text-sm text-muted-foreground">
              Automatic absence notifications, overdue fee reminders (D+1, D+7, D+15), and decoupled outbox enqueueing.
            </p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2.5">
          <button
            type="button"
            onClick={handleRunEvaluation}
            disabled={isPending}
            className="inline-flex items-center gap-2 rounded-lg border border-border bg-card px-3.5 py-2 text-sm font-medium text-foreground hover:bg-muted/80 transition-colors shadow-sm disabled:opacity-50"
          >
            <Play className="h-4 w-4 text-emerald-400" />
            Evaluate Overdue Rules
          </button>

          <button
            type="button"
            onClick={handleProcessFires}
            disabled={isPending}
            className="inline-flex items-center gap-2 rounded-lg border border-border bg-card px-3.5 py-2 text-sm font-medium text-foreground hover:bg-muted/80 transition-colors shadow-sm disabled:opacity-50"
          >
            <Send className="h-4 w-4 text-indigo-400" />
            Process Pending Queue
          </button>

          <button
            type="button"
            onClick={() => setIsCreateOpen(true)}
            className="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500 transition-colors shadow-sm"
          >
            <Plus className="h-4 w-4" />
            New Trigger Rule
          </button>
        </div>
      </div>

      {/* Metrics Row */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {/* Card 1: Active Rules */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Trigger Rules
            </span>
            <span className="rounded-full bg-emerald-500/10 border border-emerald-500/30 px-2 py-0.5 text-xs font-medium text-emerald-400">
              {data.stats.enabledRules} Active
            </span>
          </div>
          <div className="text-2xl font-bold tracking-tight text-foreground">
            {data.stats.totalRules}
          </div>
          <p className="text-xs text-muted-foreground">
            Declarative rules listening for attendance & fee events.
          </p>
        </div>

        {/* Card 2: Enqueued Fires */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Outbox Enqueued
            </span>
            <Send className="h-4 w-4 text-indigo-400" />
          </div>
          <div className="text-2xl font-bold tracking-tight text-foreground">
            {data.stats.enqueuedFires}
          </div>
          <p className="text-xs text-muted-foreground">
            Messages written to outbox outside provider transaction (AC 3).
          </p>
        </div>

        {/* Card 3: Pending Queue */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Pending Queue
            </span>
            <span className="rounded-full bg-amber-500/10 border border-amber-500/30 px-2 py-0.5 text-xs font-medium text-amber-400">
              Ready
            </span>
          </div>
          <div className="text-2xl font-bold tracking-tight text-amber-400">
            {data.stats.pendingFires}
          </div>
          <p className="text-xs text-muted-foreground">
            Trigger events waiting for next background enqueue batch.
          </p>
        </div>

        {/* Card 4: Deduplicated / Cancelled */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Cancelled / Deduped
            </span>
            <ShieldCheck className="h-4 w-4 text-emerald-400" />
          </div>
          <div className="text-2xl font-bold tracking-tight text-foreground">
            {data.stats.cancelledFires}
          </div>
          <p className="text-xs text-muted-foreground">
            Duplicate absence corrections & paid fees safely stopped (AC 1 & AC 2).
          </p>
        </div>
      </div>

      {/* Tabs */}
      <div className="border-b border-border">
        <div className="flex space-x-6">
          <button
            type="button"
            onClick={() => setActiveTab('rules')}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'rules'
                ? 'border-indigo-500 text-indigo-400 font-semibold'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Trigger Rules ({data.rules.length})
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('fires')}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'fires'
                ? 'border-indigo-500 text-indigo-400 font-semibold'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Trigger Fire Dedupe Log ({data.fires.length})
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('simulate')}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'simulate'
                ? 'border-indigo-500 text-indigo-400 font-semibold'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Evaluation & Testing
          </button>
        </div>
      </div>

      {/* Tab 1: Rules Table */}
      {activeTab === 'rules' && (
        <div className="rounded-xl border border-border/60 bg-card overflow-hidden shadow-sm">
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-muted/40 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th className="px-5 py-3.5">Rule Name</th>
                  <th className="px-5 py-3.5">Domain Event</th>
                  <th className="px-5 py-3.5">Condition & Schedule</th>
                  <th className="px-5 py-3.5">Channel</th>
                  <th className="px-5 py-3.5">Status</th>
                  <th className="px-5 py-3.5">Last Evaluated</th>
                  <th className="px-5 py-3.5 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border/50">
                {data.rules.length === 0 ? (
                  <tr>
                    <td colSpan={7} className="px-5 py-12 text-center text-muted-foreground">
                      No trigger rules defined. Click &quot;New Trigger Rule&quot; to automate notifications.
                    </td>
                  </tr>
                ) : (
                  data.rules.map((rule) => {
                    const conditionSummary =
                      rule.event_type === 'fee_challan_overdue'
                        ? `Days Overdue: ${(rule.condition?.days_overdue || [1, 7, 15]).join(', ')}`
                        : rule.event_type === 'attendance_absent'
                        ? 'Status = absent (Instant trigger)'
                        : JSON.stringify(rule.condition);

                    return (
                      <tr key={rule.id} className="hover:bg-muted/30 transition-colors">
                        <td className="px-5 py-4">
                          <div className="font-medium text-foreground">{rule.name}</div>
                          {rule.description && (
                            <p className="text-xs text-muted-foreground line-clamp-1">{rule.description}</p>
                          )}
                        </td>
                        <td className="px-5 py-4">
                          <span
                            className={`inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium ${
                              rule.event_type === 'attendance_absent'
                                ? 'bg-amber-500/10 text-amber-300 border border-amber-500/20'
                                : 'bg-blue-500/10 text-blue-300 border border-blue-500/20'
                            }`}
                          >
                            {rule.event_type === 'attendance_absent' && <Bell className="h-3 w-3" />}
                            {rule.event_type === 'fee_challan_overdue' && <Calendar className="h-3 w-3" />}
                            {rule.event_type}
                          </span>
                        </td>
                        <td className="px-5 py-4 font-mono text-xs text-muted-foreground">
                          {conditionSummary}
                        </td>
                        <td className="px-5 py-4 uppercase text-xs font-semibold text-muted-foreground">
                          {rule.channel}
                        </td>
                        <td className="px-5 py-4">
                          <button
                            type="button"
                            onClick={() => handleToggle(rule.id, rule.is_enabled)}
                            className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium transition-colors ${
                              rule.is_enabled
                                ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/30'
                                : 'bg-muted text-muted-foreground'
                            }`}
                          >
                            <Power className="h-3 w-3" />
                            {rule.is_enabled ? 'Active' : 'Disabled'}
                          </button>
                        </td>
                        <td className="px-5 py-4 font-mono text-xs text-muted-foreground">
                          {rule.last_evaluated_at
                            ? new Date(rule.last_evaluated_at).toLocaleTimeString('en-PK', {
                                hour: '2-digit',
                                minute: '2-digit',
                              })
                            : '—'}
                        </td>
                        <td className="px-5 py-4 text-right">
                          <button
                            type="button"
                            onClick={() => handleDelete(rule.id)}
                            className="text-xs text-rose-400 hover:text-rose-300 font-medium"
                          >
                            Delete
                          </button>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Tab 2: Trigger Fire Dedupe Log (AC 1 & AC 2) */}
      {activeTab === 'fires' && (
        <div className="rounded-xl border border-border/60 bg-card overflow-hidden shadow-sm space-y-4 p-5">
          <div className="flex items-center justify-between border-b pb-3">
            <div>
              <h3 className="text-base font-semibold text-foreground flex items-center gap-2">
                <ShieldCheck className="h-5 w-5 text-emerald-400" />
                Trigger Fire Audit Log & Deduplication Engine
              </h3>
              <p className="text-xs text-muted-foreground mt-0.5">
                Exact deduplication per (rule_id, entity_id, fire_key) prevents duplicate parent SMS alerts when attendance is edited or updated multiple times.
              </p>
            </div>
            <span className="rounded bg-indigo-500/10 border border-indigo-500/30 px-2.5 py-1 text-xs font-medium text-indigo-300">
              {data.fires.length} Recorded Fire(s)
            </span>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-muted/40 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th className="px-4 py-3">Rule</th>
                  <th className="px-4 py-3">Deduplication Key (fire_key)</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Fired At</th>
                  <th className="px-4 py-3">Audit Details / Skip Reason</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border/50">
                {data.fires.length === 0 ? (
                  <tr>
                    <td colSpan={5} className="px-4 py-8 text-center text-muted-foreground">
                      No trigger fires recorded yet. Mark student attendance as absent or run overdue evaluation to observe automatic fire logging.
                    </td>
                  </tr>
                ) : (
                  data.fires.map((f) => (
                    <tr key={f.id} className="hover:bg-muted/30">
                      <td className="px-4 py-3.5 font-medium text-foreground">
                        {f.rule_name}
                      </td>
                      <td className="px-4 py-3.5 font-mono text-xs text-foreground">
                        {f.fire_key}
                      </td>
                      <td className="px-4 py-3.5">
                        {f.status === 'pending' && (
                          <span className="inline-flex items-center rounded-full bg-amber-500/10 border border-amber-500/30 px-2 py-0.5 text-xs font-medium text-amber-400">
                            Pending Enqueue
                          </span>
                        )}
                        {f.status === 'enqueued' && (
                          <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 border border-emerald-500/30 px-2 py-0.5 text-xs font-medium text-emerald-400">
                            <CheckCircle2 className="h-3 w-3" />
                            Enqueued in Outbox
                          </span>
                        )}
                        {f.status === 'cancelled' && (
                          <span className="inline-flex items-center gap-1 rounded-full bg-rose-500/10 border border-rose-500/30 px-2 py-0.5 text-xs font-medium text-rose-400">
                            <XCircle className="h-3 w-3" />
                            Cancelled (Paid)
                          </span>
                        )}
                        {f.status === 'skipped' && (
                          <span className="inline-flex items-center rounded-full bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">
                            Skipped
                          </span>
                        )}
                      </td>
                      <td className="px-4 py-3.5 font-mono text-xs text-muted-foreground">
                        {new Date(f.fired_at).toLocaleTimeString('en-PK', {
                          hour: '2-digit',
                          minute: '2-digit',
                          second: '2-digit',
                        })}
                      </td>
                      <td className="px-4 py-3.5 text-xs text-muted-foreground">
                        {f.skip_reason ? (
                          <span className="text-rose-300 font-medium">{f.skip_reason}</span>
                        ) : f.enqueued_message_id ? (
                          <span className="text-emerald-400 font-mono">Msg ID: {f.enqueued_message_id.slice(0, 8)}...</span>
                        ) : (
                          'Waiting for batch dispatch'
                        )}
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Tab 3: Simulation & Testing */}
      {activeTab === 'simulate' && (
        <div className="rounded-xl border border-border/60 bg-card p-6 shadow-sm space-y-5">
          <div>
            <h3 className="text-base font-semibold text-foreground flex items-center gap-2">
              <Sparkles className="h-5 w-5 text-indigo-400" />
              Automated Rule Evaluation Engine
            </h3>
            <p className="text-xs text-muted-foreground mt-0.5">
              Simulate scheduled date evaluation for overdue fee escalations (D+1, D+7, D+15) or test attendance absence deduplication.
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-5 pt-2">
            <div className="rounded-xl border border-border p-4 space-y-3 bg-muted/20">
              <h4 className="text-sm font-semibold text-foreground flex items-center gap-2">
                <Calendar className="h-4 w-4 text-emerald-400" />
                Date-Based Rule Evaluation
              </h4>
              <p className="text-xs text-muted-foreground">
                Evaluates all unpaid and part-paid fee challans against configured offsets (e.g. D+1, D+7, D+15). Paid challans are automatically excluded.
              </p>
              <div className="flex items-center gap-3">
                <input
                  type="date"
                  value={simRunDate}
                  onChange={(e) => setSimRunDate(e.target.value)}
                  className="rounded-lg border border-border bg-background px-3 py-1.5 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
                <button
                  type="button"
                  onClick={handleRunEvaluation}
                  disabled={isPending}
                  className="rounded-lg bg-emerald-600 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-emerald-500 transition-colors disabled:opacity-50"
                >
                  Run Date Evaluation
                </button>
              </div>
            </div>

            <div className="rounded-xl border border-border p-4 space-y-3 bg-muted/20">
              <h4 className="text-sm font-semibold text-foreground flex items-center gap-2">
                <Send className="h-4 w-4 text-indigo-400" />
                Outbox Dispatch Worker
              </h4>
              <p className="text-xs text-muted-foreground">
                Processes all pending trigger fires, looks up recipient guardian phone numbers, and enqueues messages into the system outbox.
              </p>
              <div>
                <button
                  type="button"
                  onClick={handleProcessFires}
                  disabled={isPending}
                  className="rounded-lg bg-indigo-600 px-4 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors disabled:opacity-50"
                >
                  Dispatch Pending Queue
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ─── MODAL: Create Trigger Rule Modal ────────────────────────────── */}
      {isCreateOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="create-trigger-rule-title"
            className="w-full max-w-md rounded-2xl border border-border bg-card p-6 shadow-2xl space-y-4 animate-in fade-in zoom-in-95 duration-150"
          >
            <div className="flex items-center justify-between border-b pb-3">
              <div className="flex items-center gap-2">
                <Zap className="h-5 w-5 text-amber-400" />
                <h3 id="create-trigger-rule-title" className="text-base font-bold text-foreground">
                  Create Declarative Trigger Rule
                </h3>
              </div>
              <button
                type="button"
                aria-label="Close"
                onClick={() => setIsCreateOpen(false)}
                className="rounded-lg p-1 text-muted-foreground hover:bg-muted"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleCreateSubmit} className="space-y-4">
              {formError && (
                <div className="rounded-lg border border-rose-500/30 bg-rose-950/40 p-2.5 text-xs text-rose-300">
                  {formError}
                </div>
              )}

              <div>
                <label className="block text-xs font-medium text-foreground mb-1">Rule Name</label>
                <input
                  type="text"
                  required
                  placeholder="e.g. Daily Absentee Alert (SMS)"
                  value={ruleName}
                  onChange={(e) => setRuleName(e.target.value)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-foreground mb-1">Domain Event Type</label>
                <select
                  value={eventType}
                  onChange={(e) => setEventType(e.target.value as TriggerEventType)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                >
                  <option value="attendance_absent">Attendance Marked Absent (Instant Trigger)</option>
                  <option value="fee_challan_overdue">Fee Challan Overdue (Date-Based Evaluation)</option>
                  <option value="result_published">Exam Result Published</option>
                  <option value="admission_status_changed">Admission Status Change</option>
                </select>
              </div>

              {eventType === 'fee_challan_overdue' && (
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">
                    Days Overdue Offsets (comma separated)
                  </label>
                  <input
                    type="text"
                    value={daysOverdueStr}
                    onChange={(e) => setDaysOverdueStr(e.target.value)}
                    placeholder="1, 7, 15"
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <span className="text-[11px] text-muted-foreground">
                    Reminders will evaluate on D+1, D+7, and D+15 past due date.
                  </span>
                </div>
              )}

              <div>
                <label className="block text-xs font-medium text-foreground mb-1">Outbound Channel</label>
                <select
                  value={channel}
                  onChange={(e) => setChannel(e.target.value)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                >
                  <option value="sms">SMS</option>
                  <option value="whatsapp">WhatsApp</option>
                  <option value="email">Email</option>
                </select>
              </div>

              <div>
                <label className="block text-xs font-medium text-foreground mb-1">Description (Optional)</label>
                <textarea
                  rows={2}
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  placeholder="Explain when this rule triggers and who receives it..."
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
              </div>

              <div className="flex justify-end gap-2 pt-2 border-t">
                <button
                  type="button"
                  onClick={() => setIsCreateOpen(false)}
                  className="rounded-lg border border-border px-3.5 py-1.5 text-xs font-medium text-foreground hover:bg-muted"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isPending}
                  className="rounded-lg bg-indigo-600 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
                >
                  Save Trigger Rule
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}

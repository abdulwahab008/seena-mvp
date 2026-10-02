'use client';

import React, { useState, useTransition, useMemo } from 'react';
import {
  Clock,
  Moon,
  Sun,
  AlertTriangle,
  ShieldAlert,
  Send,
  Calendar,
  CheckCircle2,
  XCircle,
  Plus,
  RefreshCw,
  Sliders,
  History,
  Info,
  CalendarRange,
} from 'lucide-react';
import {
  ScheduledSendsData,
  scheduleCampaignAction,
  runDispatcherEvaluationAction,
  updateCommPolicyAction,
  createSeasonalOverrideAction,
  deleteSeasonalOverrideAction,
  cancelCampaignAction,
} from './actions';

interface Props {
  initialData: ScheduledSendsData;
}

export function ScheduledDesk({ initialData }: Props) {
  const [data, setData] = useState<ScheduledSendsData>(initialData);
  const [activeTab, setActiveTab] = useState<'campaigns' | 'bypass_logs' | 'overrides'>('campaigns');
  const [isPending, startTransition] = useTransition();

  // Dialog States
  const [isScheduleOpen, setIsScheduleOpen] = useState(false);
  const [isOverrideOpen, setIsOverrideOpen] = useState(false);
  const [isPolicyOpen, setIsPolicyOpen] = useState(false);

  // Form States - Schedule Campaign
  const [title, setTitle] = useState('');
  const [channel, setChannel] = useState('sms');
  const [segmentId, setSegmentId] = useState('');
  const [body, setBody] = useState('');
  const [scheduledAt, setScheduledAt] = useState('');
  const [isEmergency, setIsEmergency] = useState(false);
  const [emergencyReason, setEmergencyReason] = useState('');
  const [scheduleError, setScheduleError] = useState<string | null>(null);
  const [scheduleSuccess, setScheduleSuccess] = useState<string | null>(null);

  // Form States - Policy Settings
  const [quietStart, setQuietStart] = useState(initialData.policy.quiet_start.slice(0, 5));
  const [quietEnd, setQuietEnd] = useState(initialData.policy.quiet_end.slice(0, 5));
  const [policyError, setPolicyError] = useState<string | null>(null);

  // Form States - Seasonal Override
  const [overrideName, setOverrideName] = useState('Ramadan Quiet Hours');
  const [overrideStart, setOverrideStart] = useState('');
  const [overrideEnd, setOverrideEnd] = useState('');
  const [overrideQuietStart, setOverrideQuietStart] = useState('23:30');
  const [overrideQuietEnd, setOverrideQuietEnd] = useState('09:00');
  const [overrideError, setOverrideError] = useState<string | null>(null);

  // Toast / Status Message
  const [toastMessage, setToastMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  const showToast = (type: 'success' | 'error', text: string) => {
    setToastMessage({ type, text });
    setTimeout(() => setToastMessage(null), 5000);
  };

  // Real-time calculation: does scheduledAt fall in quiet hours or in past?
  const timeAnalysis = useMemo(() => {
    if (!scheduledAt) return { isPast: false, isQuiet: false, message: '' };

    const selectedDate = new Date(scheduledAt);
    const now = new Date();

    if (selectedDate.getTime() < now.getTime() - 60000) {
      return {
        isPast: true,
        isQuiet: false,
        message: 'Validation Error: Scheduled time cannot be in the past (AC 3).',
      };
    }

    // Check against active override or default policy
    const hours = selectedDate.getHours();
    const minutes = selectedDate.getMinutes();
    const timeVal = hours * 60 + minutes;

    // Default policy: 21:00 (1260 min) to 08:00 (480 min)
    const [pStartH = 21, pStartM = 0] = (data.policy.quiet_start || '21:00').split(':').map(Number);
    const [pEndH = 8, pEndM = 0] = (data.policy.quiet_end || '08:00').split(':').map(Number);
    const policyStartMin = (pStartH ?? 21) * 60 + (pStartM ?? 0);
    const policyEndMin = (pEndH ?? 8) * 60 + (pEndM ?? 0);

    let isQuiet = false;
    if (policyStartMin > policyEndMin) {
      isQuiet = timeVal >= policyStartMin || timeVal < policyEndMin;
    } else {
      isQuiet = timeVal >= policyStartMin && timeVal < policyEndMin;
    }

    if (isQuiet) {
      return {
        isPast: false,
        isQuiet: true,
        message:
          'Quiet Hours Detected (21:00–08:00 PKT). This campaign will be automatically deferred to 08:00 PKT next morning unless approved as an authorized emergency.',
      };
    }

    return {
      isPast: false,
      isQuiet: false,
      message: 'Permitted Sending Hours. Campaign will dispatch at the scheduled time.',
    };
  }, [scheduledAt, data.policy]);

  const handleScheduleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setScheduleError(null);
    setScheduleSuccess(null);

    if (!title.trim()) {
      setScheduleError('Please enter a campaign title.');
      return;
    }
    if (!scheduledAt) {
      setScheduleError('Please select a scheduled date and time.');
      return;
    }
    if (isEmergency && !emergencyReason.trim()) {
      setScheduleError('Emergency Bypass Error: A documented reason is required to bypass quiet hours compliance.');
      return;
    }

    startTransition(async () => {
      const res = await scheduleCampaignAction({
        title,
        channel,
        segmentId: segmentId || null,
        body,
        scheduledAt: new Date(scheduledAt).toISOString(),
        isEmergency,
        emergencyBypassReason: isEmergency ? emergencyReason : null,
      });

      if (!res.ok) {
        setScheduleError(res.error || 'Failed to schedule campaign');
      } else {
        if (res.data) setData(res.data);
        setScheduleSuccess('Campaign successfully registered in dispatcher!');
        showToast('success', 'Campaign scheduled successfully');
        setIsScheduleOpen(false);
        // Reset form
        setTitle('');
        setBody('');
        setScheduledAt('');
        setIsEmergency(false);
        setEmergencyReason('');
      }
    });
  };

  const handleRunDispatcher = () => {
    startTransition(async () => {
      const res = await runDispatcherEvaluationAction();
      if (!res.ok) {
        showToast('error', res.error || 'Dispatcher evaluation failed');
      } else {
        if (res.data) setData(res.data);
        const count = res.evaluations?.length || 0;
        showToast(
          'success',
          `Dispatcher evaluated successfully. ${count} campaign(s) processed/transitioned.`
        );
      }
    });
  };

  const handleSavePolicy = async (e: React.FormEvent) => {
    e.preventDefault();
    setPolicyError(null);
    startTransition(async () => {
      const res = await updateCommPolicyAction({
        quietStart: `${quietStart}:00`,
        quietEnd: `${quietEnd}:00`,
      });
      if (!res.ok) {
        setPolicyError(res.error || 'Failed to update policy');
      } else {
        if (res.data) setData(res.data);
        showToast('success', 'Quiet hours policy updated successfully');
        setIsPolicyOpen(false);
      }
    });
  };

  const handleCreateOverride = async (e: React.FormEvent) => {
    e.preventDefault();
    setOverrideError(null);
    if (!overrideStart || !overrideEnd) {
      setOverrideError('Start and end dates are required.');
      return;
    }
    startTransition(async () => {
      const res = await createSeasonalOverrideAction({
        name: overrideName,
        startDate: overrideStart,
        endDate: overrideEnd,
        quietStart: `${overrideQuietStart}:00`,
        quietEnd: `${overrideQuietEnd}:00`,
      });
      if (!res.ok) {
        setOverrideError(res.error || 'Failed to save seasonal override');
      } else {
        if (res.data) setData(res.data);
        showToast('success', 'Seasonal quiet hours override created');
        setIsOverrideOpen(false);
        setOverrideName('');
        setOverrideStart('');
        setOverrideEnd('');
      }
    });
  };

  const handleDeleteOverride = (overrideId: string) => {
    if (!confirm('Are you sure you want to delete this seasonal override?')) return;
    startTransition(async () => {
      const res = await deleteSeasonalOverrideAction(overrideId);
      if (!res.ok) {
        showToast('error', res.error || 'Failed to delete override');
      } else {
        if (res.data) setData(res.data);
        showToast('success', 'Seasonal override deleted');
      }
    });
  };

  const handleCancelCampaign = (campaignId: string) => {
    if (!confirm('Are you sure you want to cancel this scheduled campaign?')) return;
    startTransition(async () => {
      const res = await cancelCampaignAction(campaignId);
      if (!res.ok) {
        showToast('error', res.error || 'Failed to cancel campaign');
      } else {
        if (res.data) setData(res.data);
        showToast('success', 'Campaign cancelled');
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
        <div>
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-indigo-500/10 text-indigo-400 border border-indigo-500/20">
              <Clock className="h-5 w-5" />
            </div>
            <div>
              <h1 className="text-2xl font-bold tracking-tight text-foreground">
                Scheduled Sends & Quiet Hours
              </h1>
              <p className="text-sm text-muted-foreground">
                PTA anti-spam regulation compliance, automatic quiet window deferrals, and emergency break-glass dispatch.
              </p>
            </div>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2.5">
          <button
            type="button"
            onClick={handleRunDispatcher}
            disabled={isPending}
            className="inline-flex items-center gap-2 rounded-lg border border-border bg-card px-3.5 py-2 text-sm font-medium text-foreground hover:bg-muted/80 transition-colors shadow-sm disabled:opacity-50"
          >
            <RefreshCw className={`h-4 w-4 ${isPending ? 'animate-spin' : ''}`} />
            Evaluate Dispatcher
          </button>

          <button
            type="button"
            onClick={() => setIsPolicyOpen(true)}
            className="inline-flex items-center gap-2 rounded-lg border border-border bg-card px-3.5 py-2 text-sm font-medium text-foreground hover:bg-muted/80 transition-colors shadow-sm"
          >
            <Sliders className="h-4 w-4 text-muted-foreground" />
            Policy Settings
          </button>

          <button
            type="button"
            onClick={() => setIsScheduleOpen(true)}
            className="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-500 transition-colors shadow-sm"
          >
            <Plus className="h-4 w-4" />
            Schedule Campaign
          </button>
        </div>
      </div>

      {/* Stats & Current Window Card Grid */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {/* Card 1: Quiet Hours Status */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              PTA Quiet Policy
            </span>
            {data.stats.isCurrentlyQuiet ? (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-amber-500/10 border border-amber-500/30 px-2.5 py-0.5 text-xs font-medium text-amber-400">
                <Moon className="h-3 w-3" />
                Quiet Active
              </span>
            ) : (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-500/10 border border-emerald-500/30 px-2.5 py-0.5 text-xs font-medium text-emerald-400">
                <Sun className="h-3 w-3" />
                Sends Allowed
              </span>
            )}
          </div>
          <div className="text-2xl font-bold tracking-tight text-foreground">
            {data.stats.currentWindowSummary}
          </div>
          <p className="text-xs text-muted-foreground">
            {data.stats.isCurrentlyQuiet
              ? 'Campaigns evaluated now are deferred to 08:00 PKT morning.'
              : 'Direct sending permitted under Pakistan PTA window.'}
          </p>
        </div>

        {/* Card 2: Scheduled Campaigns */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Scheduled Queue
            </span>
            <span className="rounded-full bg-blue-500/10 px-2.5 py-0.5 text-xs font-medium text-blue-400">
              {data.stats.scheduledCount} Ready
            </span>
          </div>
          <div className="text-2xl font-bold tracking-tight text-foreground">
            {data.stats.totalCampaigns}
          </div>
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <span className="text-amber-400 font-medium">{data.stats.deferredQuietCount} deferred</span>
            <span>•</span>
            <span className="text-emerald-400 font-medium">{data.stats.dispatchedCount} dispatched</span>
          </div>
        </div>

        {/* Card 3: Seasonal Overrides */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Seasonal Overrides
            </span>
            <button
              onClick={() => setIsOverrideOpen(true)}
              className="text-xs text-indigo-400 hover:text-indigo-300 font-medium"
            >
              + Add Override
            </button>
          </div>
          <div className="text-2xl font-bold tracking-tight text-foreground">
            {data.overrides.length}
          </div>
          <p className="text-xs text-muted-foreground">
            {data.overrides.length > 0 && data.overrides[0]
              ? `${data.overrides[0].name} active/defined`
              : 'No special Ramadan or seasonal windows configured'}
          </p>
        </div>

        {/* Card 4: Emergency Bypasses */}
        <div className="rounded-xl border border-border/60 bg-card p-5 shadow-sm space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Emergency Bypasses
            </span>
            <ShieldAlert className="h-4 w-4 text-rose-400" />
          </div>
          <div className="text-2xl font-bold tracking-tight text-rose-400">
            {data.stats.emergencyBypassCount}
          </div>
          <p className="text-xs text-muted-foreground">
            Principal-authorized break-glass events logged for PTA audit.
          </p>
        </div>
      </div>

      {/* Tabs */}
      <div className="border-b border-border">
        <div className="flex space-x-6">
          <button
            type="button"
            onClick={() => setActiveTab('campaigns')}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'campaigns'
                ? 'border-indigo-500 text-indigo-400 font-semibold'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Campaigns ({data.campaigns.length})
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('bypass_logs')}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'bypass_logs'
                ? 'border-indigo-500 text-indigo-400 font-semibold'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Emergency Bypass Audit Log ({data.bypassLogs.length})
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('overrides')}
            className={`pb-3 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'overrides'
                ? 'border-indigo-500 text-indigo-400 font-semibold'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            Ramadan / Seasonal Overrides ({data.overrides.length})
          </button>
        </div>
      </div>

      {/* Tab 1: Campaigns Table */}
      {activeTab === 'campaigns' && (
        <div className="rounded-xl border border-border/60 bg-card overflow-hidden shadow-sm">
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-muted/40 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th className="px-5 py-3.5">Campaign Title</th>
                  <th className="px-5 py-3.5">Audience Segment</th>
                  <th className="px-5 py-3.5">Channel</th>
                  <th className="px-5 py-3.5">Scheduled (PKT)</th>
                  <th className="px-5 py-3.5">Status</th>
                  <th className="px-5 py-3.5">Deferred Resumption</th>
                  <th className="px-5 py-3.5 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border/50">
                {data.campaigns.length === 0 ? (
                  <tr>
                    <td colSpan={7} className="px-5 py-12 text-center text-muted-foreground">
                      <Clock className="mx-auto h-8 w-8 text-muted-foreground/50 mb-2" />
                      <p className="font-medium text-foreground">No scheduled campaigns yet</p>
                      <p className="text-xs">Schedule a campaign to evaluate automated quiet hours protection.</p>
                    </td>
                  </tr>
                ) : (
                  data.campaigns.map((c) => {
                    const scheduledDate = new Date(c.scheduled_at).toLocaleString('en-PK', {
                      timeZone: 'Asia/Karachi',
                      dateStyle: 'medium',
                      timeStyle: 'short',
                    });
                    const deferredDate = c.deferred_until
                      ? new Date(c.deferred_until).toLocaleString('en-PK', {
                          timeZone: 'Asia/Karachi',
                          dateStyle: 'medium',
                          timeStyle: 'short',
                        })
                      : '—';

                    return (
                      <tr key={c.id} className="hover:bg-muted/30 transition-colors">
                        <td className="px-5 py-4">
                          <div className="flex items-center gap-2">
                            <span className="font-medium text-foreground">{c.title}</span>
                            {c.is_emergency && (
                              <span className="inline-flex items-center gap-1 rounded bg-rose-500/20 border border-rose-500/30 px-1.5 py-0.5 text-[10px] font-semibold text-rose-300">
                                <AlertTriangle className="h-3 w-3" />
                                Emergency
                              </span>
                            )}
                          </div>
                          <p className="text-xs text-muted-foreground line-clamp-1 max-w-sm mt-0.5">
                            {c.body}
                          </p>
                        </td>
                        <td className="px-5 py-4 text-muted-foreground">
                          {c.segment_name ? (
                            <span className="inline-flex items-center rounded-md bg-muted px-2 py-0.5 text-xs font-medium text-foreground">
                              {c.segment_name}
                            </span>
                          ) : (
                            <span className="text-xs text-muted-foreground italic">All Campus Students</span>
                          )}
                        </td>
                        <td className="px-5 py-4">
                          <span className="uppercase text-xs font-semibold tracking-wider text-muted-foreground">
                            {c.channel}
                          </span>
                        </td>
                        <td className="px-5 py-4 font-mono text-xs text-foreground">
                          {scheduledDate}
                        </td>
                        <td className="px-5 py-4">
                          {c.status === 'scheduled' && (
                            <span className="inline-flex items-center rounded-full bg-blue-500/10 border border-blue-500/30 px-2.5 py-0.5 text-xs font-medium text-blue-400">
                              Scheduled
                            </span>
                          )}
                          {c.status === 'deferred_quiet_hours' && (
                            <span className="inline-flex items-center gap-1 rounded-full bg-amber-500/10 border border-amber-500/30 px-2.5 py-0.5 text-xs font-medium text-amber-400">
                              <Moon className="h-3 w-3" />
                              Deferred Quiet Hours
                            </span>
                          )}
                          {c.status === 'dispatching' && (
                            <span className="inline-flex items-center gap-1 rounded-full bg-purple-500/10 border border-purple-500/30 px-2.5 py-0.5 text-xs font-medium text-purple-400 animate-pulse">
                              <Send className="h-3 w-3" />
                              Dispatching
                            </span>
                          )}
                          {c.status === 'dispatched' && (
                            <span className="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 border border-emerald-500/30 px-2.5 py-0.5 text-xs font-medium text-emerald-400">
                              <CheckCircle2 className="h-3 w-3" />
                              Dispatched
                            </span>
                          )}
                          {c.status === 'cancelled' && (
                            <span className="inline-flex items-center rounded-full bg-muted px-2.5 py-0.5 text-xs font-medium text-muted-foreground">
                              Cancelled
                            </span>
                          )}
                        </td>
                        <td className="px-5 py-4 font-mono text-xs text-amber-400/90">
                          {deferredDate}
                        </td>
                        <td className="px-5 py-4 text-right">
                          {['scheduled', 'deferred_quiet_hours'].includes(c.status) && (
                            <button
                              type="button"
                              onClick={() => handleCancelCampaign(c.id)}
                              className="text-xs text-rose-400 hover:text-rose-300 font-medium"
                            >
                              Cancel
                            </button>
                          )}
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

      {/* Tab 2: Emergency Bypass Audit Log Table (AC 2) */}
      {activeTab === 'bypass_logs' && (
        <div className="rounded-xl border border-border/60 bg-card overflow-hidden shadow-sm space-y-4 p-5">
          <div className="flex items-center justify-between border-b pb-3">
            <div>
              <h3 className="text-base font-semibold text-foreground flex items-center gap-2">
                <ShieldAlert className="h-5 w-5 text-rose-400" />
                Quiet Hours Emergency Bypass Audit Log (PTA Section 7)
              </h3>
              <p className="text-xs text-muted-foreground mt-0.5">
                Every emergency override logs the authorizing Principal, exact justification reason, and timestamp for telecommunications compliance audit.
              </p>
            </div>
            <span className="rounded bg-rose-500/10 border border-rose-500/30 px-2.5 py-1 text-xs font-medium text-rose-400">
              {data.bypassLogs.length} Break-Glass Record(s)
            </span>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-border bg-muted/40 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th className="px-4 py-3">Campaign</th>
                  <th className="px-4 py-3">Approver Role</th>
                  <th className="px-4 py-3">Documented Bypass Reason</th>
                  <th className="px-4 py-3">Scheduled Time</th>
                  <th className="px-4 py-3">Immediate Dispatch</th>
                  <th className="px-4 py-3">Compliance Verification</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border/50">
                {data.bypassLogs.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                      No emergency bypasses have been executed. Standard quiet hours strictly enforced.
                    </td>
                  </tr>
                ) : (
                  data.bypassLogs.map((log) => (
                    <tr key={log.id} className="hover:bg-muted/30">
                      <td className="px-4 py-3.5 font-medium text-foreground">
                        {log.campaign_title}
                      </td>
                      <td className="px-4 py-3.5">
                        <span className="inline-flex items-center rounded-md bg-indigo-500/10 border border-indigo-500/20 px-2 py-0.5 text-xs font-medium text-indigo-300 capitalize">
                          {log.approver_role}
                        </span>
                      </td>
                      <td className="px-4 py-3.5 text-foreground max-w-md">
                        <span className="text-rose-300 font-medium">“{log.bypass_reason}”</span>
                      </td>
                      <td className="px-4 py-3.5 font-mono text-xs text-muted-foreground">
                        {new Date(log.scheduled_at).toLocaleString('en-PK', {
                          timeZone: 'Asia/Karachi',
                          dateStyle: 'short',
                          timeStyle: 'short',
                        })}
                      </td>
                      <td className="px-4 py-3.5 font-mono text-xs text-emerald-400">
                        {new Date(log.dispatched_at).toLocaleString('en-PK', {
                          timeZone: 'Asia/Karachi',
                          dateStyle: 'short',
                          timeStyle: 'short',
                        })}
                      </td>
                      <td className="px-4 py-3.5">
                        <span className="inline-flex items-center gap-1 rounded bg-emerald-500/10 border border-emerald-500/30 px-2 py-0.5 text-[11px] font-medium text-emerald-400">
                          <CheckCircle2 className="h-3 w-3" />
                          PTA Compliant Audit Entry
                        </span>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Tab 3: Seasonal & Ramadan Overrides (AC 4) */}
      {activeTab === 'overrides' && (
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <h3 className="text-base font-semibold text-foreground">
                Seasonal & Ramadan Quiet Windows (AC 4)
              </h3>
              <p className="text-xs text-muted-foreground">
                Date-range overrides that adjust quiet hour boundaries for Ramadan (e.g., 23:30 to 09:00 PKT) or seasonal schedules.
              </p>
            </div>
            <button
              type="button"
              onClick={() => setIsOverrideOpen(true)}
              className="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 transition-colors"
            >
              <Plus className="h-3.5 w-3.5" />
              Add Seasonal Override
            </button>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {data.overrides.length === 0 ? (
              <div className="col-span-full rounded-xl border border-dashed border-border p-8 text-center text-muted-foreground">
                <CalendarRange className="mx-auto h-8 w-8 text-muted-foreground/40 mb-2" />
                <p className="font-medium text-foreground">No seasonal overrides active</p>
                <p className="text-xs">Standard quiet hours (21:00 to 08:00 PKT) apply across all dates.</p>
              </div>
            ) : (
              data.overrides.map((ov) => (
                <div key={ov.id} className="rounded-xl border border-border/80 bg-card p-4 shadow-sm space-y-3">
                  <div className="flex items-center justify-between">
                    <span className="font-semibold text-foreground text-sm flex items-center gap-1.5">
                      <Moon className="h-4 w-4 text-amber-400" />
                      {ov.name}
                    </span>
                    <button
                      type="button"
                      onClick={() => handleDeleteOverride(ov.id)}
                      className="text-xs text-rose-400 hover:text-rose-300 font-medium"
                    >
                      Delete
                    </button>
                  </div>
                  <div className="text-xs space-y-1 text-muted-foreground">
                    <div className="flex items-center justify-between">
                      <span>Date Range:</span>
                      <span className="font-mono text-foreground">
                        {ov.start_date} → {ov.end_date}
                      </span>
                    </div>
                    <div className="flex items-center justify-between">
                      <span>Quiet Hours:</span>
                      <span className="font-mono font-semibold text-amber-400">
                        {ov.quiet_start.slice(0, 5)} to {ov.quiet_end.slice(0, 5)} PKT
                      </span>
                    </div>
                  </div>
                  <div className="border-t pt-2 text-[11px] text-muted-foreground flex items-center gap-1">
                    <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" />
                    Overrides default 21:00–08:00 within range
                  </div>
                </div>
              ))
            )}
          </div>
        </div>
      )}

      {/* ─── MODAL 1: Schedule Campaign Modal ────────────────────────────── */}
      {isScheduleOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="schedule-campaign-title"
            className="w-full max-w-lg rounded-2xl border border-border bg-card p-6 shadow-2xl space-y-5 animate-in fade-in zoom-in-95 duration-150"
          >
            <div className="flex items-center justify-between border-b pb-3">
              <div className="flex items-center gap-2.5">
                <Clock className="h-5 w-5 text-indigo-400" />
                <h3 id="schedule-campaign-title" className="text-lg font-bold text-foreground">
                  Schedule Message Campaign
                </h3>
              </div>
              <button
                type="button"
                aria-label="Close"
                onClick={() => setIsScheduleOpen(false)}
                className="rounded-lg p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleScheduleSubmit} className="space-y-4">
              {scheduleError && (
                <div className="rounded-xl border border-rose-500/30 bg-rose-950/40 p-3 text-xs text-rose-300 flex items-start gap-2">
                  <AlertTriangle className="h-4 w-4 shrink-0 text-rose-400 mt-0.5" />
                  <span>{scheduleError}</span>
                </div>
              )}

              {/* Title */}
              <div>
                <label className="block text-xs font-medium text-foreground mb-1">
                  Campaign Title <span className="text-rose-400">*</span>
                </label>
                <input
                  type="text"
                  required
                  placeholder="e.g. End of Term Parent Briefing"
                  value={title}
                  onChange={(e) => setTitle(e.target.value)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
              </div>

              {/* Channel & Audience Segment */}
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">Channel</label>
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
                  <label className="block text-xs font-medium text-foreground mb-1">Audience Segment</label>
                  <select
                    value={segmentId}
                    onChange={(e) => setSegmentId(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  >
                    <option value="">All Campus Students</option>
                    {data.segments.map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.name} ({s.segment_type})
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              {/* Message Body */}
              <div>
                <label className="block text-xs font-medium text-foreground mb-1">
                  Message Body <span className="text-rose-400">*</span>
                </label>
                <textarea
                  required
                  rows={3}
                  placeholder="Enter message content..."
                  value={body}
                  onChange={(e) => setBody(e.target.value)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
              </div>

              {/* Scheduled Date Time (PKT) */}
              <div>
                <label className="block text-xs font-medium text-foreground mb-1">
                  Scheduled Time (PKT) <span className="text-rose-400">*</span>
                </label>
                <input
                  type="datetime-local"
                  required
                  value={scheduledAt}
                  onChange={(e) => setScheduledAt(e.target.value)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
              </div>

              {/* Dynamic Advisory Banner */}
              {scheduledAt && (
                <div
                  className={`rounded-xl border p-3 text-xs flex items-start gap-2.5 ${
                    timeAnalysis.isPast
                      ? 'border-rose-500/40 bg-rose-950/30 text-rose-300'
                      : timeAnalysis.isQuiet
                      ? 'border-amber-500/40 bg-amber-950/30 text-amber-300'
                      : 'border-emerald-500/40 bg-emerald-950/30 text-emerald-300'
                  }`}
                >
                  {timeAnalysis.isPast ? (
                    <XCircle className="h-4 w-4 shrink-0 text-rose-400 mt-0.5" />
                  ) : timeAnalysis.isQuiet ? (
                    <Moon className="h-4 w-4 shrink-0 text-amber-400 mt-0.5" />
                  ) : (
                    <CheckCircle2 className="h-4 w-4 shrink-0 text-emerald-400 mt-0.5" />
                  )}
                  <span>{timeAnalysis.message}</span>
                </div>
              )}

              {/* Emergency Bypass Checkbox (AC 2) */}
              <div className="rounded-xl border border-rose-500/20 bg-rose-950/10 p-3.5 space-y-3">
                <label className="flex items-center gap-2.5 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={isEmergency}
                    onChange={(e) => setIsEmergency(e.target.checked)}
                    className="h-4 w-4 rounded border-border text-rose-600 focus:ring-rose-500"
                  />
                  <span className="text-xs font-semibold text-rose-300">
                    Emergency Bypass (School Closure / Disaster Alert)
                  </span>
                </label>

                {isEmergency && (
                  <div className="space-y-2 pt-1 animate-in fade-in">
                    <label className="block text-xs font-medium text-rose-200">
                      Emergency Justification Reason <span className="text-rose-400">*</span>
                    </label>
                    <textarea
                      required={isEmergency}
                      rows={2}
                      placeholder="e.g. Flash flood warning issued by DC; urgent morning closure notice."
                      value={emergencyReason}
                      onChange={(e) => setEmergencyReason(e.target.value)}
                      className="w-full rounded-lg border border-rose-500/30 bg-background px-3 py-2 text-xs text-foreground focus:outline-none focus:ring-2 focus:ring-rose-500"
                    />
                    <p className="text-[11px] text-muted-foreground flex items-center gap-1">
                      <ShieldAlert className="h-3.5 w-3.5 text-rose-400" />
                      Approver ID and reason will be immutably recorded in PTA compliance audit log.
                    </p>
                  </div>
                )}
              </div>

              {/* Actions */}
              <div className="flex justify-end gap-2.5 pt-2 border-t">
                <button
                  type="button"
                  onClick={() => setIsScheduleOpen(false)}
                  className="rounded-lg border border-border px-4 py-2 text-xs font-medium text-foreground hover:bg-muted transition-colors"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isPending}
                  className="rounded-lg bg-indigo-600 px-4 py-2 text-xs font-medium text-white hover:bg-indigo-500 transition-colors disabled:opacity-50"
                >
                  {isPending ? 'Scheduling...' : 'Save & Register Campaign'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* ─── MODAL 2: Seasonal Override Modal (AC 4) ────────────────────── */}
      {isOverrideOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="seasonal-override-title"
            className="w-full max-w-md rounded-2xl border border-border bg-card p-6 shadow-2xl space-y-4 animate-in fade-in zoom-in-95 duration-150"
          >
            <div className="flex items-center justify-between border-b pb-3">
              <div className="flex items-center gap-2">
                <Moon className="h-5 w-5 text-amber-400" />
                <h3 id="seasonal-override-title" className="text-base font-bold text-foreground">
                  Create Seasonal / Ramadan Override
                </h3>
              </div>
              <button
                type="button"
                aria-label="Close"
                onClick={() => setIsOverrideOpen(false)}
                className="rounded-lg p-1 text-muted-foreground hover:bg-muted"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleCreateOverride} className="space-y-4">
              {overrideError && (
                <div className="rounded-lg border border-rose-500/30 bg-rose-950/40 p-2.5 text-xs text-rose-300">
                  {overrideError}
                </div>
              )}

              <div>
                <label className="block text-xs font-medium text-foreground mb-1">Override Name</label>
                <input
                  type="text"
                  required
                  placeholder="e.g. Ramadan 2026 Night Schedule"
                  value={overrideName}
                  onChange={(e) => setOverrideName(e.target.value)}
                  className="w-full rounded-lg border border-border bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">Start Date</label>
                  <input
                    type="date"
                    required
                    value={overrideStart}
                    onChange={(e) => setOverrideStart(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  >
                  </input>
                </div>
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">End Date</label>
                  <input
                    type="date"
                    required
                    value={overrideEnd}
                    onChange={(e) => setOverrideEnd(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  >
                  </input>
                </div>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">Quiet Start</label>
                  <input
                    type="time"
                    required
                    value={overrideQuietStart}
                    onChange={(e) => setOverrideQuietStart(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <span className="text-[10px] text-muted-foreground">e.g. 23:30 PKT</span>
                </div>
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">Quiet End</label>
                  <input
                    type="time"
                    required
                    value={overrideQuietEnd}
                    onChange={(e) => setOverrideQuietEnd(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <span className="text-[10px] text-muted-foreground">e.g. 09:00 PKT</span>
                </div>
              </div>

              <div className="flex justify-end gap-2 pt-2 border-t">
                <button
                  type="button"
                  onClick={() => setIsOverrideOpen(false)}
                  className="rounded-lg border border-border px-3.5 py-1.5 text-xs font-medium text-foreground hover:bg-muted"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isPending}
                  className="rounded-lg bg-indigo-600 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
                >
                  Save Override
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* ─── MODAL 3: Policy Settings Modal ─────────────────────────────── */}
      {isPolicyOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm">
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="policy-settings-title"
            className="w-full max-w-sm rounded-2xl border border-border bg-card p-6 shadow-2xl space-y-4 animate-in fade-in zoom-in-95 duration-150"
          >
            <div className="flex items-center justify-between border-b pb-3">
              <div className="flex items-center gap-2">
                <Sliders className="h-5 w-5 text-indigo-400" />
                <h3 id="policy-settings-title" className="text-base font-bold text-foreground">
                  Default Quiet Hours Policy
                </h3>
              </div>
              <button
                type="button"
                aria-label="Close"
                onClick={() => setIsPolicyOpen(false)}
                className="rounded-lg p-1 text-muted-foreground hover:bg-muted"
              >
                ✕
              </button>
            </div>

            <form onSubmit={handleSavePolicy} className="space-y-4">
              {policyError && (
                <div className="rounded-lg border border-rose-500/30 bg-rose-950/40 p-2.5 text-xs text-rose-300">
                  {policyError}
                </div>
              )}

              <div>
                <label className="block text-xs font-medium text-foreground mb-1">Timezone</label>
                <input
                  type="text"
                  disabled
                  value="Asia/Karachi (PKT, UTC+5)"
                  className="w-full rounded-lg border border-border bg-muted/50 px-3 py-2 text-xs font-mono text-muted-foreground cursor-not-allowed"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">Quiet Window Start</label>
                  <input
                    type="time"
                    required
                    value={quietStart}
                    onChange={(e) => setQuietStart(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <span className="text-[10px] text-muted-foreground">Default: 21:00</span>
                </div>
                <div>
                  <label className="block text-xs font-medium text-foreground mb-1">Quiet Window End</label>
                  <input
                    type="time"
                    required
                    value={quietEnd}
                    onChange={(e) => setQuietEnd(e.target.value)}
                    className="w-full rounded-lg border border-border bg-background px-3 py-2 text-xs font-mono text-foreground focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  />
                  <span className="text-[10px] text-muted-foreground">Default: 08:00</span>
                </div>
              </div>

              <div className="rounded-lg bg-muted/40 p-3 text-[11px] text-muted-foreground">
                <Info className="h-3.5 w-3.5 inline mr-1 text-indigo-400" />
                Under PTA regulations, standard commercial and bulk broadcast sends are prohibited between 21:00 and 08:00 PKT.
              </div>

              <div className="flex justify-end gap-2 pt-2 border-t">
                <button
                  type="button"
                  onClick={() => setIsPolicyOpen(false)}
                  className="rounded-lg border border-border px-3.5 py-1.5 text-xs font-medium text-foreground hover:bg-muted"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={isPending}
                  className="rounded-lg bg-indigo-600 px-3.5 py-1.5 text-xs font-medium text-white hover:bg-indigo-500 disabled:opacity-50"
                >
                  Update Policy
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}

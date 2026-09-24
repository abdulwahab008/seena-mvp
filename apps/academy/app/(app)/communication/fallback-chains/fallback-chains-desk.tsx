'use client';

import React, { useState } from 'react';
import {
  Route,
  Clock,
  ShieldAlert,
  ArrowRight,
  Plus,
  Play,
  RotateCcw,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Coins,
  Trash2,
  Send,
  Sliders,
  Check,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Modal } from '@/components/ui/modal';
import {
  CommChannel,
  CommChannelChainRow,
  CommOptOutRow,
  FallbackMessageReportRow,
  saveChannelChain,
  saveOptOut,
  removeOptOut,
  triggerTimeoutScan,
  simulateReceiptWebhook,
} from './actions';

interface Props {
  initialChains: CommChannelChainRow[];
  initialOptOuts: CommOptOutRow[];
  initialEscalations: FallbackMessageReportRow[];
}

export function FallbackChainsDesk({
  initialChains,
  initialOptOuts,
  initialEscalations,
}: Props) {
  const [chains, setChains] = useState<CommChannelChainRow[]>(initialChains);
  const [optOuts, setOptOuts] = useState<CommOptOutRow[]>(initialOptOuts);
  const [escalations, setEscalations] = useState<FallbackMessageReportRow[]>(initialEscalations);

  const [activeTab, setActiveTab] = useState<'chains' | 'escalations' | 'optouts' | 'simulator'>('chains');

  // Chain Modal State
  const [isChainModalOpen, setIsChainModalOpen] = useState(false);
  const [chainClass, setChainClass] = useState('attendance');
  const [chainChannels, setChainChannels] = useState<CommChannel[]>(['whatsapp', 'sms']);
  const [chainWaitSec, setChainWaitSec] = useState<Record<string, number>>({
    whatsapp: 900,
    sms: 600,
    email: 3600,
    push: 300,
  });
  const [chainDesc, setChainDesc] = useState('');
  const [isSavingChain, setIsSavingChain] = useState(false);
  const [chainError, setChainError] = useState<string | null>(null);

  // Opt-out Modal State
  const [isOptOutModalOpen, setIsOptOutModalOpen] = useState(false);
  const [optOutPhone, setOptOutPhone] = useState('');
  const [optOutChannel, setOptOutChannel] = useState<CommChannel>('sms');
  const [optOutReason, setOptOutReason] = useState('Parent requested SMS stop');
  const [isSavingOptOut, setIsSavingOptOut] = useState(false);
  const [optOutError, setOptOutError] = useState<string | null>(null);

  // Scanner State
  const [isScanning, setIsScanning] = useState(false);
  const [scanMessage, setScanMessage] = useState<string | null>(null);

  // Webhook Simulator State
  const [simAttemptId, setSimAttemptId] = useState('');
  const [simStatus, setSimStatus] = useState<'delivered' | 'undelivered' | 'failed'>('undelivered');
  const [simErrorCode, setSimErrorCode] = useState('UNDELIVERED_UNREGISTERED');
  const [isSimulating, setIsSimulating] = useState(false);
  const [simResult, setSimResult] = useState<string | null>(null);

  // Handle Save Chain
  const handleSaveChain = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSavingChain(true);
    setChainError(null);

    const res = await saveChannelChain({
      message_class: chainClass,
      ordered_channels: chainChannels,
      wait_seconds: chainWaitSec,
      description: chainDesc,
    });

    setIsSavingChain(false);
    if (res.success) {
      setIsChainModalOpen(false);
      window.location.reload();
    } else {
      setChainError(res.error || 'Failed to save chain configuration');
    }
  };

  // Handle Save Opt-Out
  const handleSaveOptOut = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSavingOptOut(true);
    setOptOutError(null);

    const res = await saveOptOut({
      recipient_phone: optOutPhone,
      channel: optOutChannel,
      reason: optOutReason,
    });

    setIsSavingOptOut(false);
    if (res.success) {
      setIsOptOutModalOpen(false);
      setOptOutPhone('');
      window.location.reload();
    } else {
      setOptOutError(res.error || 'Failed to record opt-out');
    }
  };

  // Handle Remove Opt-Out
  const handleRemoveOptOut = async (id: string) => {
    const res = await removeOptOut(id);
    if (res.success) {
      setOptOuts((prev) => prev.filter((o) => o.id !== id));
    }
  };

  // Trigger Timeout Scanner
  const handleTriggerScanner = async () => {
    setIsScanning(true);
    setScanMessage(null);

    const res = await triggerTimeoutScan();
    setIsScanning(false);
    if (res.success) {
      setScanMessage(`Scan finished: ${res.escalated_count} timed-out attempts escalated to next channel.`);
      setTimeout(() => setScanMessage(null), 5000);
      window.location.reload();
    } else {
      setScanMessage(`Scanner error: ${res.error}`);
    }
  };

  // Trigger Webhook Simulation
  const handleSimulateWebhook = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!simAttemptId) return;
    setIsSimulating(true);
    setSimResult(null);

    const res = await simulateReceiptWebhook({
      attempt_id: simAttemptId,
      receipt_status: simStatus,
      error_code: simErrorCode,
    });

    setIsSimulating(false);
    if (res.success) {
      setSimResult(`Receipt applied: ${res.new_status}. Fallback evaluated.`);
      setTimeout(() => setSimResult(null), 5000);
      window.location.reload();
    } else {
      setSimResult(`Simulation error: ${res.error}`);
    }
  };

  const toggleChannel = (ch: CommChannel) => {
    if (chainChannels.includes(ch)) {
      if (chainChannels.length > 1) {
        setChainChannels((prev) => prev.filter((c) => c !== ch));
      }
    } else {
      setChainChannels((prev) => [...prev, ch]);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header Banner */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-border pb-5">
        <div>
          <div className="flex items-center gap-2.5">
            <div className="p-2 rounded-lg bg-indigo-500/10 text-indigo-600 dark:text-indigo-400">
              <Route className="w-5 h-5" />
            </div>
            <h1 className="text-xl font-bold tracking-tight text-foreground">
              Channel Fallback Chains
            </h1>
            <span className="text-xs px-2.5 py-0.5 rounded-full font-semibold bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300">
              FR-M02
            </span>
          </div>
          <p className="text-xs text-muted-foreground mt-1 max-w-2xl">
            Automated per-recipient multi-channel fallback (WhatsApp ➔ SMS ➔ Push), delivery receipt timeouts, opt-out suppression, and honest multi-hop cost ledgering.
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            onClick={handleTriggerScanner}
            disabled={isScanning}
            className="text-xs"
          >
            <Clock className="w-3.5 h-3.5 mr-1 text-amber-600" />
            {isScanning ? 'Scanning...' : 'Scan Timeouts'}
          </Button>

          <Button
            size="sm"
            variant="outline"
            onClick={() => setIsOptOutModalOpen(true)}
            className="text-xs"
          >
            <ShieldAlert className="w-3.5 h-3.5 mr-1 text-rose-600" />
            Capture Opt-Out
          </Button>

          <Button
            size="sm"
            onClick={() => {
              setChainClass('emergency');
              setChainChannels(['sms', 'whatsapp']);
              setChainDesc('Immediate emergency delivery sequence');
              setIsChainModalOpen(true);
            }}
            className="text-xs"
          >
            <Plus className="w-3.5 h-3.5 mr-1" />
            Configure Chain
          </Button>
        </div>
      </div>

      {scanMessage && (
        <div className="p-3 bg-blue-50 dark:bg-blue-950/40 border border-blue-200 dark:border-blue-900 rounded-md text-xs text-blue-900 dark:text-blue-200 flex items-center justify-between">
          <span>{scanMessage}</span>
          <button onClick={() => setScanMessage(null)} className="text-xs font-bold">✕</button>
        </div>
      )}

      {/* Tabs */}
      <div className="flex border-b border-border gap-2">
        <button
          onClick={() => setActiveTab('chains')}
          className={`pb-2.5 px-3 text-xs font-semibold border-b-2 transition-all flex items-center gap-1.5 ${
            activeTab === 'chains'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <Sliders className="w-3.5 h-3.5" /> Fallback Rules ({chains.length})
        </button>
        <button
          onClick={() => setActiveTab('escalations')}
          className={`pb-2.5 px-3 text-xs font-semibold border-b-2 transition-all flex items-center gap-1.5 ${
            activeTab === 'escalations'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <RotateCcw className="w-3.5 h-3.5" /> Escalations & Cost Ledger ({escalations.length})
        </button>
        <button
          onClick={() => setActiveTab('optouts')}
          className={`pb-2.5 px-3 text-xs font-semibold border-b-2 transition-all flex items-center gap-1.5 ${
            activeTab === 'optouts'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <ShieldAlert className="w-3.5 h-3.5" /> Opt-Out Suppression ({optOuts.length})
        </button>
        <button
          onClick={() => setActiveTab('simulator')}
          className={`pb-2.5 px-3 text-xs font-semibold border-b-2 transition-all flex items-center gap-1.5 ${
            activeTab === 'simulator'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          <Play className="w-3.5 h-3.5" /> Webhook & Receipt Simulator
        </button>
      </div>

      {/* TAB 1: FALLBACK CHAINS */}
      {activeTab === 'chains' && (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {chains.map((chain) => (
            <div
              key={chain.id}
              className="border border-border rounded-lg p-4 bg-card shadow-sm flex flex-col justify-between gap-3"
            >
              <div>
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <span className="font-bold text-sm uppercase tracking-wide px-2 py-0.5 bg-muted rounded">
                      {chain.message_class}
                    </span>
                    {chain.is_active ? (
                      <span className="text-[10px] bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300 px-2 py-0.5 rounded-full font-semibold flex items-center gap-1">
                        <CheckCircle2 className="w-2.5 h-2.5" /> Active
                      </span>
                    ) : (
                      <span className="text-[10px] bg-zinc-200 text-zinc-700 px-2 py-0.5 rounded-full">
                        Inactive
                      </span>
                    )}
                  </div>
                  <span className="text-[10px] text-muted-foreground">
                    {chain.ordered_channels.length} Hops
                  </span>
                </div>

                {chain.description && (
                  <p className="text-xs text-muted-foreground mt-2">{chain.description}</p>
                )}

                {/* Ordered Pipeline Visualization */}
                <div className="mt-4 pt-3 border-t border-border">
                  <label className="text-[11px] font-semibold text-muted-foreground uppercase tracking-wider block mb-2">
                    Escalation Sequence & Delivery Windows:
                  </label>
                  <div className="flex items-center gap-2 flex-wrap">
                    {chain.ordered_channels.map((ch, idx) => {
                      const waitSec = chain.wait_seconds?.[ch] || 900;
                      return (
                        <React.Fragment key={ch}>
                          <div className="flex flex-col items-center bg-muted/50 border border-border rounded p-2 text-center min-w-[90px]">
                            <span className="text-[10px] font-bold uppercase text-primary">
                              Hop {idx + 1}: {ch}
                            </span>
                            <span className="text-[9px] text-muted-foreground font-mono mt-0.5">
                              Timeout: {Math.round(waitSec / 60)}m ({waitSec}s)
                            </span>
                          </div>
                          {idx < chain.ordered_channels.length - 1 && (
                            <ArrowRight className="w-3.5 h-3.5 text-muted-foreground" />
                          )}
                        </React.Fragment>
                      );
                    })}
                  </div>
                </div>
              </div>

              <div className="flex items-center justify-between pt-2 border-t border-border text-[11px] text-muted-foreground">
                <span>Updated: {new Date(chain.updated_at).toLocaleDateString()}</span>
                <Button
                  size="sm"
                  variant="ghost"
                  className="h-6 text-[11px]"
                  onClick={() => {
                    setChainClass(chain.message_class);
                    setChainChannels(chain.ordered_channels);
                    setChainWaitSec(chain.wait_seconds);
                    setChainDesc(chain.description || '');
                    setIsChainModalOpen(true);
                  }}
                >
                  Edit Rule
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* TAB 2: ESCALATIONS & COST AUDIT */}
      {activeTab === 'escalations' && (
        <div className="border border-border rounded-lg bg-card overflow-hidden">
          <div className="p-3 bg-muted/40 border-b border-border flex items-center justify-between">
            <div>
              <h3 className="text-xs font-bold uppercase tracking-wider text-foreground">
                Fallback Routing Log & Multi-Hop Audit
              </h3>
              <p className="text-[11px] text-muted-foreground">
                Inspect messages that traversed the fallback chain, late delivery handling, and honest dual cost tracking.
              </p>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="bg-muted/30 text-muted-foreground font-semibold border-b border-border">
                <tr>
                  <th className="p-3">Recipient</th>
                  <th className="p-3">Class</th>
                  <th className="p-3">Attempt Progression (Hops)</th>
                  <th className="p-3">Final Status</th>
                  <th className="p-3">Cost Ledger (Paisa)</th>
                  <th className="p-3">Dispatched</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {escalations.length === 0 ? (
                  <tr>
                    <td colSpan={6} className="p-6 text-center text-muted-foreground">
                      No fallback routing messages recorded yet.
                    </td>
                  </tr>
                ) : (
                  escalations.map((msg) => {
                    const totalCost = msg.costs.reduce((sum, c) => sum + c.cost_paisa, 0);

                    return (
                      <tr key={msg.id} className="hover:bg-muted/20">
                        <td className="p-3 font-mono font-medium">
                          {msg.recipient_phone || 'N/A'}
                          <div className="text-[10px] text-muted-foreground capitalize">
                            {msg.recipient_type}
                          </div>
                        </td>
                        <td className="p-3">
                          <span className="px-1.5 py-0.5 rounded text-[10px] font-semibold bg-muted uppercase">
                            {msg.message_class}
                          </span>
                        </td>
                        <td className="p-3">
                          <div className="flex items-center gap-1.5 flex-wrap">
                            {msg.attempts.map((att, aIdx) => (
                              <React.Fragment key={att.id}>
                                <div
                                  className={`px-2 py-0.5 rounded text-[10px] border font-mono flex items-center gap-1 ${
                                    att.status === 'delivered'
                                      ? 'bg-emerald-50 dark:bg-emerald-950/40 border-emerald-300 text-emerald-800 dark:text-emerald-300'
                                      : att.status === 'undelivered' || att.status === 'failed'
                                      ? 'bg-rose-50 dark:bg-rose-950/40 border-rose-300 text-rose-800 dark:text-rose-300'
                                      : att.status === 'timeout'
                                      ? 'bg-amber-50 dark:bg-amber-950/40 border-amber-300 text-amber-800 dark:text-amber-300'
                                      : att.status === 'skipped'
                                      ? 'bg-zinc-100 dark:bg-zinc-800 border-zinc-300 text-zinc-600 line-through'
                                      : 'bg-blue-50 dark:bg-blue-950/40 border-blue-300 text-blue-800'
                                  }`}
                                >
                                  <span>#{att.attempt_number} {att.channel}: {att.status}</span>
                                  {att.skip_reason && (
                                    <span className="text-[9px] italic">({att.skip_reason})</span>
                                  )}
                                </div>
                                {aIdx < msg.attempts.length - 1 && (
                                  <ArrowRight className="w-3 h-3 text-muted-foreground" />
                                )}
                              </React.Fragment>
                            ))}
                          </div>
                        </td>
                        <td className="p-3">
                          <span
                            className={`px-2 py-0.5 rounded-full font-semibold text-[10px] ${
                              msg.final_status === 'delivered'
                                ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300'
                                : msg.final_status === 'exhausted'
                                ? 'bg-purple-100 text-purple-800 dark:bg-purple-950 dark:text-purple-300'
                                : msg.final_status === 'failed'
                                ? 'bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300'
                                : 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300'
                            }`}
                          >
                            {msg.final_status || msg.status}
                          </span>
                        </td>
                        <td className="p-3">
                          <div className="font-mono font-semibold flex items-center gap-1">
                            <Coins className="w-3 h-3 text-amber-600" />
                            {totalCost} paisa ({(totalCost / 100).toFixed(2)} PKR)
                          </div>
                          <div className="text-[10px] text-muted-foreground">
                            {msg.costs.length} billable attempts
                          </div>
                        </td>
                        <td className="p-3 text-[11px] text-muted-foreground">
                          {new Date(msg.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
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

      {/* TAB 3: OPT-OUT SUPPRESSION */}
      {activeTab === 'optouts' && (
        <div className="border border-border rounded-lg bg-card overflow-hidden">
          <div className="p-4 bg-muted/40 border-b border-border flex items-center justify-between">
            <div>
              <h3 className="text-xs font-bold uppercase tracking-wider text-foreground">
                Channel Opt-Out Suppression Catalog
              </h3>
              <p className="text-[11px] text-muted-foreground">
                Recipients who have opted out of specific channels (e.g. SMS stop requests). The fallback engine will automatically skip opted-out channels and escalate to the next hop.
              </p>
            </div>
            <Button
              size="sm"
              variant="outline"
              onClick={() => setIsOptOutModalOpen(true)}
              className="text-xs"
            >
              <Plus className="w-3 h-3 mr-1" /> Add Suppression
            </Button>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="bg-muted/30 text-muted-foreground font-semibold border-b border-border">
                <tr>
                  <th className="p-3">Recipient Identifier</th>
                  <th className="p-3">Suppressed Channel</th>
                  <th className="p-3">Reason / Source</th>
                  <th className="p-3">Opted-Out Date</th>
                  <th className="p-3 text-right">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {optOuts.length === 0 ? (
                  <tr>
                    <td colSpan={5} className="p-6 text-center text-muted-foreground">
                      No active opt-out records found. All recipients receive notifications on all configured channels.
                    </td>
                  </tr>
                ) : (
                  optOuts.map((o) => (
                    <tr key={o.id} className="hover:bg-muted/20">
                      <td className="p-3 font-mono font-medium">
                        {o.recipient_phone || o.recipient_email || 'N/A'}
                      </td>
                      <td className="p-3">
                        <span className="px-2 py-0.5 rounded font-mono uppercase text-[10px] bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300 font-bold">
                          {o.channel}
                        </span>
                      </td>
                      <td className="p-3 text-muted-foreground">
                        {o.reason || 'Requested by parent'}
                      </td>
                      <td className="p-3 text-muted-foreground font-mono">
                        {new Date(o.opted_out_at).toLocaleDateString()}
                      </td>
                      <td className="p-3 text-right">
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => handleRemoveOptOut(o.id)}
                          className="text-rose-600 hover:text-rose-700 h-6 px-2 text-xs"
                        >
                          <Trash2 className="w-3 h-3 mr-1" /> Unblock
                        </Button>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* TAB 4: WEBHOOK & RECEIPT SIMULATOR */}
      {activeTab === 'simulator' && (
        <div className="border border-border rounded-lg p-5 bg-card max-w-xl">
          <div className="flex items-center gap-2 mb-3">
            <Play className="w-4 h-4 text-primary" />
            <h3 className="text-sm font-bold">Aggregator Delivery Webhook Simulator</h3>
          </div>
          <p className="text-xs text-muted-foreground mb-4">
            Simulate an incoming WhatsApp/SMS delivery receipt webhook from Jazz, Zong, or Meta WhatsApp Cloud to test immediate fallback triggers and multi-hop reporting.
          </p>

          {simResult && (
            <div className="mb-4 p-3 bg-emerald-50 dark:bg-emerald-950/40 border border-emerald-300 rounded text-xs text-emerald-900 dark:text-emerald-200">
              {simResult}
            </div>
          )}

          <form onSubmit={handleSimulateWebhook} className="space-y-4">
            <div>
              <label className="text-xs font-semibold block mb-1">Target Attempt ID *</label>
              <input
                type="text"
                required
                placeholder="e.g. paste a message_attempt UUID"
                value={simAttemptId}
                onChange={(e) => setSimAttemptId(e.target.value)}
                className="w-full text-xs font-mono border border-input rounded-md px-3 py-2 bg-background"
              />
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-xs font-semibold block mb-1">Receipt Status</label>
                <select
                  value={simStatus}
                  onChange={(e) => setSimStatus(e.target.value as any)}
                  className="w-full text-xs border border-input rounded-md px-2.5 py-2 bg-background"
                >
                  <option value="undelivered">undelivered (Trigger Fallback)</option>
                  <option value="delivered">delivered (Mark Successful)</option>
                  <option value="failed">failed (Aggregator Error)</option>
                </select>
              </div>

              <div>
                <label className="text-xs font-semibold block mb-1">Error Code</label>
                <input
                  type="text"
                  value={simErrorCode}
                  onChange={(e) => setSimErrorCode(e.target.value)}
                  className="w-full text-xs font-mono border border-input rounded-md px-3 py-2 bg-background"
                />
              </div>
            </div>

            <Button type="submit" disabled={isSimulating} className="w-full text-xs">
              <Send className="w-3.5 h-3.5 mr-1" />
              {isSimulating ? 'Applying Webhook...' : 'Dispatch Simulated Webhook Receipt'}
            </Button>
          </form>
        </div>
      )}

      {/* CREATE / EDIT CHAIN MODAL */}
      <Modal
        open={isChainModalOpen}
        onClose={() => setIsChainModalOpen(false)}
        title="Configure Channel Fallback Chain"
        description="Define the sequential retry path and delivery timeout windows for this message category."
      >
        <form onSubmit={handleSaveChain} className="space-y-4 pt-2">
          {chainError && (
            <div className="p-2.5 rounded bg-rose-50 dark:bg-rose-950/40 border border-rose-200 text-xs text-rose-700">
              {chainError}
            </div>
          )}

          <div>
            <label className="text-xs font-semibold block mb-1">Message Class *</label>
            <input
              type="text"
              required
              placeholder="e.g. emergency, fee, attendance, general"
              value={chainClass}
              onChange={(e) => setChainClass(e.target.value)}
              className="w-full text-xs border border-input rounded-md px-3 py-2 bg-background font-mono"
            />
          </div>

          <div>
            <label className="text-xs font-semibold block mb-1">
              Select & Order Fallback Channels (Left to Right):
            </label>
            <div className="flex gap-2 flex-wrap mb-2">
              {(['whatsapp', 'sms', 'email', 'push'] as CommChannel[]).map((ch) => {
                const isSelected = chainChannels.includes(ch);
                return (
                  <button
                    type="button"
                    key={ch}
                    onClick={() => toggleChannel(ch)}
                    className={`px-3 py-1 text-xs rounded border flex items-center gap-1 font-semibold uppercase ${
                      isSelected
                        ? 'bg-primary text-primary-foreground border-primary'
                        : 'bg-background border-border text-muted-foreground'
                    }`}
                  >
                    {isSelected && <Check className="w-3 h-3" />}
                    {ch}
                  </button>
                );
              })}
            </div>
            <p className="text-[10px] text-muted-foreground">
              Current Sequence: {chainChannels.join(' ➔ ')}
            </p>
          </div>

          <div>
            <label className="text-xs font-semibold block mb-1">
              Delivery Timeout Windows (Seconds):
            </label>
            <div className="grid grid-cols-2 gap-2">
              {chainChannels.map((ch) => (
                <div key={ch} className="flex items-center gap-2 border border-border p-2 rounded bg-muted/20">
                  <span className="text-xs font-mono uppercase w-16">{ch}:</span>
                  <input
                    type="number"
                    min="1"
                    value={chainWaitSec[ch] || 600}
                    onChange={(e) =>
                      setChainWaitSec((prev) => ({
                        ...prev,
                        [ch]: parseInt(e.target.value, 10) || 60,
                      }))
                    }
                    className="text-xs border border-input rounded px-2 py-1 w-full bg-background font-mono"
                  />
                  <span className="text-[10px] text-muted-foreground">sec</span>
                </div>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs font-semibold block mb-1">Description / Notes</label>
            <input
              type="text"
              placeholder="e.g. Critical notification with fast SMS fallback"
              value={chainDesc}
              onChange={(e) => setChainDesc(e.target.value)}
              className="w-full text-xs border border-input rounded-md px-3 py-2 bg-background"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2 border-t border-border">
            <Button type="button" variant="outline" onClick={() => setIsChainModalOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSavingChain}>
              {isSavingChain ? 'Saving...' : 'Save Fallback Chain'}
            </Button>
          </div>
        </form>
      </Modal>

      {/* CAPTURE OPT-OUT MODAL */}
      <Modal
        open={isOptOutModalOpen}
        onClose={() => setIsOptOutModalOpen(false)}
        title="Capture Channel Opt-Out"
        description="Suppress messages on a specific channel at the recipient's request. The fallback engine will automatically bypass this channel."
      >
        <form onSubmit={handleSaveOptOut} className="space-y-4 pt-2">
          {optOutError && (
            <div className="p-2.5 rounded bg-rose-50 dark:bg-rose-950/40 border border-rose-200 text-xs text-rose-700">
              {optOutError}
            </div>
          )}

          <div>
            <label className="text-xs font-semibold block mb-1">Recipient Mobile Number *</label>
            <input
              type="text"
              required
              placeholder="+923001234567"
              value={optOutPhone}
              onChange={(e) => setOptOutPhone(e.target.value)}
              className="w-full text-xs border border-input rounded-md px-3 py-2 bg-background font-mono"
            />
          </div>

          <div>
            <label className="text-xs font-semibold block mb-1">Channel to Suppress *</label>
            <select
              value={optOutChannel}
              onChange={(e) => setOptOutChannel(e.target.value as CommChannel)}
              className="w-full text-xs border border-input rounded-md px-2.5 py-2 bg-background"
            >
              <option value="sms">SMS</option>
              <option value="whatsapp">WhatsApp</option>
              <option value="email">Email</option>
              <option value="push">Push Notification</option>
            </select>
          </div>

          <div>
            <label className="text-xs font-semibold block mb-1">Reason / Source</label>
            <input
              type="text"
              value={optOutReason}
              onChange={(e) => setOptOutReason(e.target.value)}
              className="w-full text-xs border border-input rounded-md px-3 py-2 bg-background"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2 border-t border-border">
            <Button type="button" variant="outline" onClick={() => setIsOptOutModalOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSavingOptOut}>
              {isSavingOptOut ? 'Recording...' : 'Record Opt-Out'}
            </Button>
          </div>
        </form>
      </Modal>
    </div>
  );
}

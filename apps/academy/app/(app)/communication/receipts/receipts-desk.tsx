'use client';

import React, { useState } from 'react';
import { runStaleSweeperAction, submitSimulatedReceiptAction } from './actions';

interface DeliveryStats {
  campaign_id: string | null;
  total_messages: number;
  total_attempts: number;
  delivered_count: number;
  failed_count: number;
  expired_count: number;
  pending_sent_count: number;
  delivery_rate_pct: number;
}

interface ReceiptItem {
  id: string;
  provider: string;
  provider_ref: string;
  status: string;
  raw: any;
  received_at: string;
  message_attempt_id: string | null;
}

interface DeadLetterItem {
  id: string;
  provider: string;
  provider_ref: string;
  payload: any;
  reason: string;
  received_at: string;
  expires_at: string;
}

interface ReceiptsDeskProps {
  stats: DeliveryStats[];
  receipts: ReceiptItem[];
  deadLetters: DeadLetterItem[];
  role: string;
}

export function ReceiptsDesk({
  stats,
  receipts: initialReceipts,
  deadLetters: initialDeadLetters,
  role,
}: ReceiptsDeskProps) {
  const [activeTab, setActiveTab] = useState<'stats' | 'receipts' | 'dead_letters'>('stats');
  const [isSweeping, setIsSweeping] = useState(false);
  const [isSimulating, setIsSimulating] = useState(false);
  const [message, setMessage] = useState<{ text: string; type: 'success' | 'error' } | null>(null);

  // Simulation form
  const [simProvider, setSimProvider] = useState('jazz_sms');
  const [simRef, setSimRef] = useState('');
  const [simStatus, setSimStatus] = useState('delivered');

  // Compute overall aggregates
  const totalAttempts = stats.reduce((acc, s) => acc + (s.total_attempts || 0), 0);
  const totalDelivered = stats.reduce((acc, s) => acc + (s.delivered_count || 0), 0);
  const totalFailed = stats.reduce((acc, s) => acc + (s.failed_count || 0), 0);
  const totalExpired = stats.reduce((acc, s) => acc + (s.expired_count || 0), 0);
  const overallRate = totalAttempts > 0 ? ((totalDelivered / totalAttempts) * 100).toFixed(1) : '0.0';

  const handleSweep = async () => {
    setIsSweeping(true);
    setMessage(null);
    try {
      const res = await runStaleSweeperAction(24);
      if (res.success) {
        setMessage({
          text: `Stale sweeper completed: ${res.expiredCount} unreached attempts marked as 'expired'.`,
          type: 'success',
        });
      } else {
        setMessage({ text: res.error || 'Failed to run sweeper', type: 'error' });
      }
    } catch (err: any) {
      setMessage({ text: err.message || 'Error executing sweeper', type: 'error' });
    } finally {
      setIsSweeping(false);
    }
  };

  const handleSimulateReceipt = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!simRef.trim()) return;
    setIsSimulating(true);
    setMessage(null);
    try {
      const res = await submitSimulatedReceiptAction(simProvider, simRef.trim(), simStatus);
      if (res.success) {
        setMessage({
          text: `Receipt processed (${res.result?.action || 'applied'}). Status: ${res.result?.new_status || res.result?.status || 'recorded'}`,
          type: 'success',
        });
        setSimRef('');
      } else {
        setMessage({ text: res.error || 'Failed to process receipt', type: 'error' });
      }
    } catch (err: any) {
      setMessage({ text: err.message || 'Error processing receipt', type: 'error' });
    } finally {
      setIsSimulating(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Top Banner & Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b pb-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">
            Delivery Receipt Ingestion & Analytics
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Asynchronous DLR ingestion, monotonic state transitions, dead-letter audit & 24h stale sweeper.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={handleSweep}
            disabled={isSweeping}
            className="inline-flex items-center justify-center rounded-md bg-amber-600 hover:bg-amber-700 text-white text-xs font-medium px-3 py-2 shadow-sm transition-colors disabled:opacity-50"
          >
            {isSweeping ? 'Sweeping...' : 'Run Stale Sweeper (24h)'}
          </button>
        </div>
      </div>

      {message && (
        <div
          className={`p-3 rounded-md text-sm ${
            message.type === 'success'
              ? 'bg-emerald-50 text-emerald-800 border border-emerald-200'
              : 'bg-rose-50 text-rose-800 border border-rose-200'
          }`}
        >
          {message.text}
        </div>
      )}

      {/* Aggregate KPI Cards */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
        <div className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm">
          <div className="text-xs font-medium text-muted-foreground">Overall Delivery Rate</div>
          <div className="text-2xl font-bold text-foreground mt-1">{overallRate}%</div>
          <div className="text-xs text-muted-foreground mt-0.5">{totalDelivered} reached</div>
        </div>
        <div className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm">
          <div className="text-xs font-medium text-muted-foreground">Total Dispatched</div>
          <div className="text-2xl font-bold text-foreground mt-1">{totalAttempts}</div>
          <div className="text-xs text-muted-foreground mt-0.5">Attempt records</div>
        </div>
        <div className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm">
          <div className="text-xs font-medium text-muted-foreground">Delivered</div>
          <div className="text-2xl font-bold text-emerald-600 mt-1">{totalDelivered}</div>
          <div className="text-xs text-muted-foreground mt-0.5">Parent confirmed</div>
        </div>
        <div className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm">
          <div className="text-xs font-medium text-muted-foreground">Expired (Unreached)</div>
          <div className="text-2xl font-bold text-amber-600 mt-1">{totalExpired}</div>
          <div className="text-xs text-muted-foreground mt-0.5">Swept after 24h</div>
        </div>
        <div className="p-4 rounded-lg border bg-card text-card-foreground shadow-sm">
          <div className="text-xs font-medium text-muted-foreground">Dead-Letter Count</div>
          <div className="text-2xl font-bold text-rose-600 mt-1">{initialDeadLetters.length}</div>
          <div className="text-xs text-muted-foreground mt-0.5">Unmatched refs</div>
        </div>
      </div>

      {/* Tab Navigation */}
      <div className="border-b border-border flex items-center gap-4">
        <button
          onClick={() => setActiveTab('stats')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'stats'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Campaign Delivery Breakdown
        </button>
        <button
          onClick={() => setActiveTab('receipts')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'receipts'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Recent Receipts Log ({initialReceipts.length})
        </button>
        <button
          onClick={() => setActiveTab('dead_letters')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'dead_letters'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Dead-Letter Queue ({initialDeadLetters.length})
        </button>
      </div>

      {/* Quick Test Ingestion Bar */}
      <form onSubmit={handleSimulateReceipt} className="p-4 border rounded-lg bg-muted/40 space-y-3">
        <div className="text-xs font-semibold text-foreground uppercase tracking-wider">
          Receipt Ingestion Test Tool (AC 1, AC 2 & AC 3 Test Harness)
        </div>
        <div className="grid grid-cols-1 md:grid-cols-4 gap-3">
          <div>
            <label className="text-xs text-muted-foreground">Provider</label>
            <select
              value={simProvider}
              onChange={(e) => setSimProvider(e.target.value)}
              className="mt-1 w-full rounded border px-2 py-1.5 text-xs bg-background"
            >
              <option value="jazz_sms">Jazz SMS</option>
              <option value="telenor_sms">Telenor SMS</option>
              <option value="zong_sms">Zong SMS</option>
              <option value="whatsapp_cloud_api">WhatsApp Cloud API</option>
            </select>
          </div>
          <div>
            <label className="text-xs text-muted-foreground">Provider Reference</label>
            <input
              type="text"
              placeholder="e.g. PROV-REF-1234"
              value={simRef}
              onChange={(e) => setSimRef(e.target.value)}
              className="mt-1 w-full rounded border px-2 py-1.5 text-xs bg-background"
            />
          </div>
          <div>
            <label className="text-xs text-muted-foreground">Incoming Status</label>
            <select
              value={simStatus}
              onChange={(e) => setSimStatus(e.target.value)}
              className="mt-1 w-full rounded border px-2 py-1.5 text-xs bg-background"
            >
              <option value="delivered">delivered</option>
              <option value="sent">sent</option>
              <option value="submitted">submitted</option>
              <option value="failed">failed</option>
              <option value="expired">expired</option>
            </select>
          </div>
          <div className="flex items-end">
            <button
              type="submit"
              disabled={isSimulating || !simRef.trim()}
              className="w-full rounded bg-primary hover:bg-primary/90 text-primary-foreground text-xs font-medium py-2 transition-colors disabled:opacity-50"
            >
              {isSimulating ? 'Applying...' : 'Apply Receipt'}
            </button>
          </div>
        </div>
      </form>

      {/* Tab 1: Stats Table */}
      {activeTab === 'stats' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Campaign / Batch</th>
                <th className="p-3">Total Messages</th>
                <th className="p-3">Total Attempts</th>
                <th className="p-3 text-emerald-600">Delivered</th>
                <th className="p-3 text-amber-600">Expired</th>
                <th className="p-3 text-rose-600">Failed</th>
                <th className="p-3">Pending Sent</th>
                <th className="p-3">Delivery Rate</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {stats.length === 0 ? (
                <tr>
                  <td colSpan={8} className="p-4 text-center text-muted-foreground">
                    No campaign delivery data available yet.
                  </td>
                </tr>
              ) : (
                stats.map((s, idx) => (
                  <tr key={idx} className="hover:bg-muted/20">
                    <td className="p-3 font-mono text-foreground">
                      {s.campaign_id ? s.campaign_id.slice(0, 8) + '...' : 'Direct Dispatch'}
                    </td>
                    <td className="p-3 font-medium">{s.total_messages}</td>
                    <td className="p-3">{s.total_attempts}</td>
                    <td className="p-3 text-emerald-600 font-semibold">{s.delivered_count}</td>
                    <td className="p-3 text-amber-600 font-semibold">{s.expired_count}</td>
                    <td className="p-3 text-rose-600 font-semibold">{s.failed_count}</td>
                    <td className="p-3">{s.pending_sent_count}</td>
                    <td className="p-3">
                      <div className="flex items-center gap-2">
                        <div className="w-16 bg-muted rounded-full h-2 overflow-hidden">
                          <div
                            className="bg-emerald-500 h-2 rounded-full"
                            style={{ width: `${Math.min(s.delivery_rate_pct, 100)}%` }}
                          />
                        </div>
                        <span className="font-semibold">{s.delivery_rate_pct}%</span>
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* Tab 2: Receipts Audit Stream */}
      {activeTab === 'receipts' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Received At</th>
                <th className="p-3">Provider</th>
                <th className="p-3">Provider Ref</th>
                <th className="p-3">Status</th>
                <th className="p-3">Attempt ID</th>
                <th className="p-3">Raw Payload</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {initialReceipts.length === 0 ? (
                <tr>
                  <td colSpan={6} className="p-4 text-center text-muted-foreground">
                    No delivery receipts ingested yet.
                  </td>
                </tr>
              ) : (
                initialReceipts.map((r) => (
                  <tr key={r.id} className="hover:bg-muted/20">
                    <td className="p-3 whitespace-nowrap text-muted-foreground">
                      {new Date(r.received_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
                    </td>
                    <td className="p-3 font-medium">{r.provider}</td>
                    <td className="p-3 font-mono">{r.provider_ref}</td>
                    <td className="p-3">
                      <span
                        className={`px-2 py-0.5 rounded text-[10px] font-semibold uppercase ${
                          r.status === 'delivered'
                            ? 'bg-emerald-100 text-emerald-800'
                            : r.status === 'failed'
                            ? 'bg-rose-100 text-rose-800'
                            : r.status === 'expired'
                            ? 'bg-amber-100 text-amber-800'
                            : 'bg-blue-100 text-blue-800'
                        }`}
                      >
                        {r.status}
                      </span>
                    </td>
                    <td className="p-3 font-mono text-muted-foreground">
                      {r.message_attempt_id ? r.message_attempt_id.slice(0, 8) + '...' : '—'}
                    </td>
                    <td className="p-3 font-mono text-[10px] text-muted-foreground truncate max-w-xs">
                      {JSON.stringify(r.raw)}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* Tab 3: Dead-Letter Queue (30-day retention) */}
      {activeTab === 'dead_letters' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <div className="p-3 bg-muted/30 border-b flex items-center justify-between text-xs">
            <span className="text-muted-foreground">
              Payloads with unmatched provider references are retained for 30 days before auto-purge.
            </span>
            <span className="font-semibold text-rose-600">
              {initialDeadLetters.length} Unmatched Receipts
            </span>
          </div>
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Received At</th>
                <th className="p-3">Provider</th>
                <th className="p-3">Provider Ref</th>
                <th className="p-3">Reason</th>
                <th className="p-3">Retained Until</th>
                <th className="p-3">Payload</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {initialDeadLetters.length === 0 ? (
                <tr>
                  <td colSpan={6} className="p-4 text-center text-muted-foreground">
                    Dead-letter queue is clear. No unmatched delivery receipts.
                  </td>
                </tr>
              ) : (
                initialDeadLetters.map((dl) => (
                  <tr key={dl.id} className="hover:bg-muted/20">
                    <td className="p-3 whitespace-nowrap text-muted-foreground">
                      {new Date(dl.received_at).toLocaleTimeString()}
                    </td>
                    <td className="p-3 font-medium">{dl.provider}</td>
                    <td className="p-3 font-mono text-rose-700">{dl.provider_ref}</td>
                    <td className="p-3 font-mono text-[11px] text-amber-700">{dl.reason}</td>
                    <td className="p-3 text-muted-foreground whitespace-nowrap">
                      {new Date(dl.expires_at).toLocaleDateString()} (30d)
                    </td>
                    <td className="p-3 font-mono text-[10px] text-muted-foreground truncate max-w-xs">
                      {JSON.stringify(dl.payload)}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

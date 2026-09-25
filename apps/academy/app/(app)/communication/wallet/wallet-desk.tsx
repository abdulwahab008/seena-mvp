'use client';

import React, { useState } from 'react';
import { useRouter } from 'next/navigation';
import { topUpWalletAction, checkCampaignCreditGuardAction } from './actions';

interface RateCardItem {
  id: string;
  channel: string;
  encoding: string;
  network: string;
  rate_paisa: number;
  effective_from: string;
  effective_to: string | null;
}

interface WalletTxn {
  id: string;
  txn_type: string;
  amount_paisa: number;
  balance_after_paisa: number;
  reference: string;
  created_at: string;
}

interface LedgerItem {
  id: string;
  channel: string;
  units: number;
  cost_paisa: number;
  conversation_id: string | null;
  status: string;
  created_at: string;
}

interface MonthlySpend {
  billing_month: string;
  channel: string;
  total_units: number;
  total_spend_pkr: number;
}

interface WalletDeskProps {
  balancePaisa: number;
  currency: string;
  rateCards: RateCardItem[];
  transactions: WalletTxn[];
  ledger: LedgerItem[];
  monthlySpend: MonthlySpend[];
  role: string;
}

export function WalletDesk({
  balancePaisa: initialBalance,
  currency,
  rateCards,
  transactions,
  ledger,
  monthlySpend,
  role,
}: WalletDeskProps) {
  const router = useRouter();
  const [balancePaisa, setBalancePaisa] = useState(initialBalance);
  const [txnList, setTxnList] = useState(transactions);
  const [topUpAmount, setTopUpAmount] = useState('5000');
  const [topUpRef, setTopUpRef] = useState('JazzCash / Bank Transfer');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [notice, setNotice] = useState<{ text: string; type: 'success' | 'error' } | null>(null);

  const [activeTab, setActiveTab] = useState<'rates' | 'transactions' | 'ledger' | 'monthly'>('rates');

  const balancePkr = (balancePaisa / 100).toLocaleString('en-PK', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });

  const handleTopUp = async (e: React.FormEvent) => {
    e.preventDefault();
    const amount = parseFloat(topUpAmount);
    if (!amount || amount <= 0) return;

    setIsSubmitting(true);
    setNotice(null);
    try {
      const res = await topUpWalletAction(amount, topUpRef);
      if (res.success) {
        const newBalance = Number(res.newBalancePaisa);
        setBalancePaisa(newBalance);
        setTxnList((prev) => [
          {
            id: 'temp-' + Date.now(),
            txn_type: 'top_up',
            amount_paisa: Math.round(amount * 100),
            balance_after_paisa: newBalance,
            reference: topUpRef,
            created_at: new Date().toISOString(),
          },
          ...prev,
        ]);
        setNotice({
          text: `Wallet credited with PKR ${amount.toLocaleString()}. New Balance: PKR ${(newBalance / 100).toLocaleString()}`,
          type: 'success',
        });
        router.refresh();
      } else {
        setNotice({ text: res.error || 'Failed to top up wallet', type: 'error' });
      }
    } catch (err: any) {
      setNotice({ text: err.message || 'Error processing top-up', type: 'error' });
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b pb-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-foreground">
            Message Cost Ledger & Credit Guard
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Prepaid balance controls, effective-dated rate cards, exact PKR unit costing & credit exhaustion guard.
          </p>
        </div>
      </div>

      {notice && (
        <div
          className={`p-3 rounded-md text-sm ${
            notice.type === 'success'
              ? 'bg-emerald-50 text-emerald-800 border border-emerald-200'
              : 'bg-rose-50 text-rose-800 border border-rose-200'
          }`}
        >
          {notice.text}
        </div>
      )}

      {/* Top Section: Wallet Balance & Quick Top-Up */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {/* Balance Card */}
        <div className="p-6 rounded-xl border bg-gradient-to-br from-card to-muted/40 shadow-sm flex flex-col justify-between">
          <div>
            <div className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Prepaid Messaging Balance
            </div>
            <div className="text-4xl font-black text-foreground mt-3 flex items-baseline gap-2">
              <span className="text-2xl font-medium text-muted-foreground">PKR</span>
              <span>{balancePkr}</span>
            </div>
            <div className="text-xs text-muted-foreground mt-2">
              Exact ledger: <span className="font-mono">{balancePaisa.toLocaleString()} paisa</span>
            </div>
          </div>
          <div className="mt-6 pt-4 border-t flex items-center justify-between text-xs">
            <span
              className={`inline-flex items-center px-2 py-0.5 rounded-full font-medium ${
                balancePaisa > 100000
                  ? 'bg-emerald-100 text-emerald-800'
                  : balancePaisa > 20000
                  ? 'bg-amber-100 text-amber-800'
                  : 'bg-rose-100 text-rose-800'
              }`}
            >
              {balancePaisa > 100000 ? 'Healthy Balance' : balancePaisa > 20000 ? 'Low Credit' : 'Critical / Empty'}
            </span>
            <span className="text-muted-foreground">Enforced before dispatch</span>
          </div>
        </div>

        {/* Top-Up Form */}
        <div className="md:col-span-2 p-6 rounded-xl border bg-card shadow-sm">
          <div className="text-sm font-semibold text-foreground">Top-Up Messaging Wallet</div>
          <p className="text-xs text-muted-foreground mt-1">
            Deposit prepaid credit to prevent automated campaigns from hitting the credit guard.
          </p>

          <form onSubmit={handleTopUp} className="mt-4 space-y-4">
            <div className="flex flex-wrap gap-2">
              {[2000, 5000, 10000, 25000, 50000].map((amt) => (
                <button
                  key={amt}
                  type="button"
                  onClick={() => setTopUpAmount(amt.toString())}
                  className={`px-3 py-1.5 rounded-md text-xs font-medium border transition-colors ${
                    topUpAmount === amt.toString()
                      ? 'bg-primary text-primary-foreground border-primary'
                      : 'bg-background hover:bg-muted text-foreground'
                  }`}
                >
                  PKR {amt.toLocaleString()}
                </button>
              ))}
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div>
                <label className="text-xs text-muted-foreground font-medium">Custom Amount (PKR)</label>
                <input
                  type="number"
                  min="1"
                  step="any"
                  value={topUpAmount}
                  onChange={(e) => setTopUpAmount(e.target.value)}
                  className="mt-1 w-full rounded border px-3 py-2 text-sm bg-background"
                  placeholder="5000"
                />
              </div>
              <div>
                <label className="text-xs text-muted-foreground font-medium">Payment Reference / Note</label>
                <input
                  type="text"
                  value={topUpRef}
                  onChange={(e) => setTopUpRef(e.target.value)}
                  className="mt-1 w-full rounded border px-3 py-2 text-sm bg-background"
                  placeholder="e.g. JazzCash Ref #88291"
                />
              </div>
            </div>

            <div className="flex justify-end">
              <button
                type="submit"
                disabled={isSubmitting || !topUpAmount}
                className="rounded-md bg-primary hover:bg-primary/90 text-primary-foreground text-xs font-semibold px-4 py-2 transition-colors disabled:opacity-50"
              >
                {isSubmitting ? 'Crediting...' : 'Add Credit to Wallet'}
              </button>
            </div>
          </form>
        </div>
      </div>

      {/* Tabs Section */}
      <div className="border-b border-border flex items-center gap-4">
        <button
          onClick={() => setActiveTab('rates')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'rates'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Effective Rate Cards
        </button>
        <button
          onClick={() => setActiveTab('ledger')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'ledger'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Cost Ledger Entries ({ledger.length})
        </button>
        <button
          onClick={() => setActiveTab('transactions')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'transactions'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Wallet Transaction Audit ({transactions.length})
        </button>
        <button
          onClick={() => setActiveTab('monthly')}
          className={`pb-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === 'monthly'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          Monthly Spend
        </button>
      </div>

      {/* Tab 1: Rate Cards */}
      {activeTab === 'rates' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Channel</th>
                <th className="p-3">Encoding / Type</th>
                <th className="p-3">Network</th>
                <th className="p-3">Rate (Paisa)</th>
                <th className="p-3">Rate (PKR)</th>
                <th className="p-3">Effective From</th>
                <th className="p-3">Effective To</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {rateCards.map((rc) => (
                <tr key={rc.id} className="hover:bg-muted/20">
                  <td className="p-3 font-semibold uppercase">{rc.channel}</td>
                  <td className="p-3">
                    <span className="font-mono text-xs">
                      {rc.encoding === 'ucs2' ? 'Urdu (UCS-2)' : rc.encoding === 'gsm7' ? 'English (GSM-7)' : rc.encoding}
                    </span>
                  </td>
                  <td className="p-3 font-medium capitalize">{rc.network}</td>
                  <td className="p-3 font-mono font-semibold">{rc.rate_paisa} paisa</td>
                  <td className="p-3 font-mono text-emerald-600 font-bold">
                    PKR {(rc.rate_paisa / 100).toFixed(2)} / unit
                  </td>
                  <td className="p-3 text-muted-foreground">{rc.effective_from}</td>
                  <td className="p-3 text-muted-foreground">{rc.effective_to || 'Active (Current)'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Tab 2: Cost Ledger */}
      {activeTab === 'ledger' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Time</th>
                <th className="p-3">Channel</th>
                <th className="p-3">Units</th>
                <th className="p-3">Cost (Paisa)</th>
                <th className="p-3">Cost (PKR)</th>
                <th className="p-3">Conversation ID</th>
                <th className="p-3">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {ledger.length === 0 ? (
                <tr>
                  <td colSpan={7} className="p-4 text-center text-muted-foreground">
                    No cost ledger rows recorded yet.
                  </td>
                </tr>
              ) : (
                ledger.map((item) => (
                  <tr key={item.id} className="hover:bg-muted/20">
                    <td className="p-3 whitespace-nowrap text-muted-foreground">
                      {new Date(item.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                    </td>
                    <td className="p-3 font-semibold uppercase">{item.channel}</td>
                    <td className="p-3 font-medium">{item.units}</td>
                    <td className="p-3 font-mono">{item.cost_paisa}</td>
                    <td className="p-3 font-mono text-emerald-600 font-bold">
                      PKR {(item.cost_paisa / 100).toFixed(2)}
                    </td>
                    <td className="p-3 font-mono text-muted-foreground">
                      {item.conversation_id || '—'}
                    </td>
                    <td className="p-3">
                      <span className="px-2 py-0.5 rounded text-[10px] font-semibold bg-emerald-100 text-emerald-800">
                        {item.status}
                      </span>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* Tab 3: Transactions */}
      {activeTab === 'transactions' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Date & Time</th>
                <th className="p-3">Type</th>
                <th className="p-3">Amount (PKR)</th>
                <th className="p-3">Balance After</th>
                <th className="p-3">Reference</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {txnList.length === 0 ? (
                <tr>
                  <td colSpan={5} className="p-4 text-center text-muted-foreground">
                    No wallet transactions recorded.
                  </td>
                </tr>
              ) : (
                txnList.map((t) => (
                  <tr key={t.id} className="hover:bg-muted/20">
                    <td className="p-3 text-muted-foreground whitespace-nowrap">
                      {new Date(t.created_at).toLocaleString()}
                    </td>
                    <td className="p-3">
                      <span
                        className={`px-2 py-0.5 rounded text-[10px] font-semibold uppercase ${
                          t.txn_type === 'top_up'
                            ? 'bg-emerald-100 text-emerald-800'
                            : 'bg-rose-100 text-rose-800'
                        }`}
                      >
                        {t.txn_type}
                      </span>
                    </td>
                    <td className="p-3 font-mono font-bold">
                      {t.txn_type === 'top_up' ? '+' : '-'} PKR {(t.amount_paisa / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                    </td>
                    <td className="p-3 font-mono text-muted-foreground">
                      PKR {(t.balance_after_paisa / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                    </td>
                    <td className="p-3 text-foreground">{t.reference}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* Tab 4: Monthly Spend */}
      {activeTab === 'monthly' && (
        <div className="border rounded-lg overflow-hidden bg-card">
          <table className="w-full text-xs text-left">
            <thead className="bg-muted/50 border-b font-medium text-muted-foreground">
              <tr>
                <th className="p-3">Billing Month</th>
                <th className="p-3">Channel</th>
                <th className="p-3">Total Units</th>
                <th className="p-3">Total Spend (PKR)</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {monthlySpend.length === 0 ? (
                <tr>
                  <td colSpan={4} className="p-4 text-center text-muted-foreground">
                    No monthly spend data available.
                  </td>
                </tr>
              ) : (
                monthlySpend.map((ms, idx) => (
                  <tr key={idx} className="hover:bg-muted/20">
                    <td className="p-3 font-medium">{ms.billing_month}</td>
                    <td className="p-3 uppercase font-semibold">{ms.channel}</td>
                    <td className="p-3 font-mono">{ms.total_units}</td>
                    <td className="p-3 font-mono font-bold text-foreground">
                      PKR {ms.total_spend_pkr.toLocaleString()}
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

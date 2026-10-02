'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import { assemblePacket, readPacketPlan } from './actions';
import {
  PACKET_STATUS_LABEL,
  cardOnlySummary,
  type PacketCandidate,
  type PacketPlan,
} from '@/lib/exams/packet-query';
import { formatPkr } from '@/lib/challan/html';
import type { MarkSectionOption } from '@/lib/exams/mark-query';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

type Props = { examTermId: string; sections: MarkSectionOption[] };

type Outcome = { state: 'done' | 'error'; message: string; downloadUrl?: string };

export function PacketBoard({ examTermId, sections }: Props) {
  const [sectionId, setSectionId] = useState('');
  const [billingPeriod, setBillingPeriod] = useState('');
  const [plan, setPlan] = useState<PacketPlan | null>(null);
  const [loading, setLoading] = useState(false);
  const [running, setRunning] = useState(false);
  const [outcomes, setOutcomes] = useState<Record<string, Outcome>>({});

  const load = async () => {
    if (!sectionId) return;
    setLoading(true);
    const r = await readPacketPlan({ examTermId, sectionId, billingPeriod });
    setLoading(false);
    if (r.error || !r.plan) {
      toast.error(r.error ?? 'Could not read the plan.');
      setPlan(null);
      return;
    }
    setPlan(r.plan);
  };

  const assembleOne = async (c: PacketCandidate) => {
    const r = await assemblePacket({ enrolmentId: c.enrolment_id, examTermId, billingPeriod });
    setOutcomes((o) => ({
      ...o,
      [c.enrolment_id]: r.error
        ? { state: 'error', message: r.error }
        : { state: 'done', message: r.withChallan ? 'Card + challan' : 'Card only', downloadUrl: r.downloadUrl },
    }));
    return !r.error;
  };

  const assembleAll = async () => {
    if (!plan) return;
    setRunning(true);
    let ok = 0;
    const todo = plan.candidates.filter((c) => c.status === 'with_challan' || c.status === 'card_only');
    for (const c of todo) {
      if (await assembleOne(c)) ok += 1;
    }
    setRunning(false);
    toast.success(`${ok} of ${todo.length} packets assembled.`);
    await load();
  };

  const summary = plan ? cardOnlySummary(plan) : null;

  return (
    <div className="space-y-6">
      <section className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="packet-section">Section</Label>
          <select
            id="packet-section"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={sectionId}
            data-testid="packet-section-select"
            onChange={(e) => {
              setSectionId(e.target.value);
              setPlan(null);
            }}
          >
            <option value="">Choose a section…</option>
            {sections.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="packet-period">Challan month (optional)</Label>
          <input
            id="packet-period"
            type="month"
            className="h-9 rounded-md border bg-background px-3 text-sm"
            value={billingPeriod}
            data-testid="packet-period"
            onChange={(e) => {
              setBillingPeriod(e.target.value);
              setPlan(null);
            }}
          />
        </div>
        <Button variant="outline" disabled={loading || !sectionId} data-testid="open-packets" onClick={() => void load()}>
          {loading ? 'Opening…' : 'Plan packets'}
        </Button>
      </section>

      {plan && (
        <div className="space-y-4" data-testid="packet-plan">
          <div className="rounded-md border p-4 text-sm" data-testid="packet-summary">
            <p>
              <span data-testid="packet-count-with-challan">{plan.with_challan_count}</span> with a challan ·{' '}
              <span data-testid="packet-count-card-only">{plan.card_only_count}</span> card only ·{' '}
              <span data-testid="packet-count-withheld">{plan.withheld_count}</span> withheld ·{' '}
              <span data-testid="packet-count-no-card">{plan.no_card_count}</span> without an issued card
            </p>
            {summary && (
              <p className="mt-2 text-muted-foreground" data-testid="packet-card-only-summary">
                {summary} {plan.card_only.join(', ')}.
              </p>
            )}
          </div>

          <Button disabled={running} data-testid="assemble-all" onClick={() => void assembleAll()}>
            {running ? 'Assembling…' : 'Assemble all packets'}
          </Button>

          <table className="w-full text-sm">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Student</th>
                <th className="py-1">Status</th>
                <th className="py-1">Challan</th>
                <th className="py-1">Payable</th>
                <th className="py-1" />
              </tr>
            </thead>
            <tbody>
              {plan.candidates.map((c) => {
                const out = outcomes[c.enrolment_id];
                const canAssemble = c.status === 'with_challan' || c.status === 'card_only';
                return (
                  <tr key={c.enrolment_id} className="border-t align-top" data-testid={`packet-${c.gr_number}`}>
                    <td className="py-2">
                      {c.roll_no !== null ? `${c.roll_no}. ` : ''}
                      {c.student_name}
                      <span className="block text-xs text-muted-foreground">{c.gr_number}</span>
                    </td>
                    <td className="py-2" data-testid={`packet-status-${c.gr_number}`}>
                      {PACKET_STATUS_LABEL[c.status]}
                    </td>
                    <td className="py-2">{c.challan_no ?? '—'}</td>
                    <td className="py-2" data-testid={`packet-payable-${c.gr_number}`}>
                      {c.payable_paisa === null ? '—' : formatPkr(c.payable_paisa)}
                    </td>
                    <td className="py-2 text-right">
                      {out?.state === 'error' && (
                        <span className="block text-xs text-destructive" role="alert">
                          {out.message}
                        </span>
                      )}
                      {out?.state === 'done' && out.downloadUrl ? (
                        <a href={out.downloadUrl} className="underline" data-testid={`packet-download-${c.gr_number}`}>
                          Download ({out.message})
                        </a>
                      ) : c.assembled && c.packet_id ? (
                        <a
                          href={`/api/report-card-packets/${c.packet_id}/download`}
                          className="underline"
                          data-testid={`packet-download-${c.gr_number}`}
                        >
                          Download
                        </a>
                      ) : null}
                      {canAssemble && (
                        <Button
                          size="sm"
                          variant="outline"
                          className="ml-2"
                          disabled={running}
                          data-testid={`assemble-${c.gr_number}`}
                          onClick={() => void assembleOne(c).then(() => load())}
                        >
                          {c.assembled ? 'Re-assemble' : 'Assemble'}
                        </Button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import {
  cancelInterview,
  fetchInterviewNotificationPayload,
  submitScorecard,
  fetchScorecardSummary,
  type NotificationPayload,
  type ScorecardSummary,
} from './actions';
import { INTERVIEW_CRITERIA, INTERVIEW_RECOMMENDATIONS } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type InterviewRow = {
  id: string;
  applicationId: string;
  applicationNo: string | null;
  childName: string;
  panelName: string;
  startsAt: string;
  endsAt: string;
  venue: string | null;
  status: string;
};

function NotificationViewer({ interviewId }: { interviewId: string }) {
  const [pending, startTransition] = useTransition();
  const [payload, setPayload] = useState<NotificationPayload | null>(null);

  const onView = () => {
    startTransition(async () => {
      const result = await fetchInterviewNotificationPayload(interviewId);
      if (result.error) toast.error(result.error);
      else setPayload(result.payload);
    });
  };

  return (
    <div className="mt-1">
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onView}>
        Preview notification
      </Button>
      {payload && (
        <p className="mt-1 text-xs text-muted-foreground" data-testid={`notification-preview-${interviewId}`}>
          Channel: {payload.channel} · {payload.phone}
        </p>
      )}
    </div>
  );
}

function CancelButton({ interviewId }: { interviewId: string }) {
  const [pending, startTransition] = useTransition();

  const onCancel = () => {
    startTransition(async () => {
      const result = await cancelInterview(interviewId);
      if (result.error) toast.error(result.error);
      else toast.success('Interview cancelled.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onCancel}>
      Cancel
    </Button>
  );
}

function ScorecardForm({ interviewId }: { interviewId: string }) {
  const [pending, startTransition] = useTransition();
  const [scores, setScores] = useState<Record<string, string>>({});
  const [recommendation, setRecommendation] = useState('');
  const [justification, setJustification] = useState('');

  const onSubmit = () => {
    const fd = new FormData();
    fd.set('interviewId', interviewId);
    fd.set('scores', JSON.stringify(scores));
    fd.set('recommendation', recommendation);
    if (justification) fd.set('justification', justification);
    startTransition(async () => {
      const result = await submitScorecard({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Scorecard submitted.');
    });
  };

  return (
    <div className="mt-2 space-y-2 border-t pt-2">
      <div className="flex flex-wrap gap-2">
        {INTERVIEW_CRITERIA.map((c) => (
          <div key={c} className="w-32">
            <label className="text-xs text-muted-foreground">{c.replace(/_/g, ' ')}</label>
            <Input
              type="number"
              min={1}
              max={5}
              className="h-8"
              value={scores[c] ?? ''}
              onChange={(e) => setScores((s) => ({ ...s, [c]: e.target.value }))}
              data-testid={`scorecard-${c}-${interviewId}`}
            />
          </div>
        ))}
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <Select value={recommendation} onValueChange={setRecommendation}>
          <SelectTrigger className="h-8 w-32" data-testid={`scorecard-recommendation-${interviewId}`}>
            <SelectValue placeholder="Recommend" />
          </SelectTrigger>
          <SelectContent>
            {INTERVIEW_RECOMMENDATIONS.map((r) => (
              <SelectItem key={r} value={r}>
                {r}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Input
          placeholder="Justification (needed for merit overrides)"
          className="h-8 w-72"
          value={justification}
          onChange={(e) => setJustification(e.target.value)}
          data-testid={`scorecard-justification-${interviewId}`}
        />
        <Button type="button" size="sm" disabled={pending || !recommendation} onClick={onSubmit} data-testid={`scorecard-submit-${interviewId}`}>
          Submit scorecard
        </Button>
      </div>
    </div>
  );
}

function ScorecardComparison({ applicationId }: { applicationId: string }) {
  const [pending, startTransition] = useTransition();
  const [summary, setSummary] = useState<ScorecardSummary | null>(null);

  const onView = () => {
    startTransition(async () => {
      const result = await fetchScorecardSummary(applicationId);
      if (result.error) toast.error(result.error);
      else setSummary(result.summary);
    });
  };

  return (
    <div className="mt-1">
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onView}>
        View scorecards
      </Button>
      {summary && (
        <div className="mt-1 space-y-1 text-xs" data-testid={`scorecard-comparison-${applicationId}`}>
          {summary.scorecards.map((s) => (
            <p key={s.interview_id}>
              {s.panel_name}: {s.recommendation} — {Object.entries(s.scores).map(([c, v]) => `${c}:${v}`).join(', ')}
            </p>
          ))}
          <p className="text-muted-foreground">
            Mean —{' '}
            {Object.entries(summary.mean_by_criterion)
              .map(([c, v]) => `${c}:${v}`)
              .join(', ')}
          </p>
        </div>
      )}
    </div>
  );
}

export function InterviewList({ interviews }: { interviews: InterviewRow[] }) {
  if (interviews.length === 0) {
    return <p className="text-sm text-muted-foreground">No interviews booked yet.</p>;
  }

  return (
    <div className="space-y-2">
      {interviews.map((i) => (
        <Card key={i.id} data-testid={`interview-row-${i.id}`}>
          <CardContent className="p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="font-medium">
                  {i.childName} ({i.applicationNo}) with {i.panelName}
                </p>
                <p className="text-sm text-muted-foreground">
                  {new Date(i.startsAt).toLocaleString()} – {new Date(i.endsAt).toLocaleTimeString()} · {i.venue ?? 'No venue set'} ·{' '}
                  <span data-testid={`interview-status-${i.id}`}>{i.status}</span>
                </p>
                <NotificationViewer interviewId={i.id} />
                <ScorecardComparison applicationId={i.applicationId} />
              </div>
              {i.status === 'scheduled' && <CancelButton interviewId={i.id} />}
            </div>
            <ScorecardForm interviewId={i.id} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';

// FR-H06: when the teacher checks a submission the student's page updates on
// its own. Subscribes only once a session is confirmed (same timing reason as
// HomeworkRealtimeRefresher); RLS limits the events to the student's own rows.
export function SubmissionRealtimeRefresher({ enrolmentId }: { enrolmentId: string }) {
  const router = useRouter();
  const [status, setStatus] = useState('connecting');

  useEffect(() => {
    const supabase = supabaseBrowser();
    let channel: ReturnType<typeof supabase.channel> | undefined;
    let subscribed = false;
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!session) return;
      supabase.realtime.setAuth(session.access_token);
      if (subscribed) return;
      subscribed = true;
      channel = supabase
        .channel(`homework-submission-${enrolmentId}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'homework_submission', filter: `enrolment_id=eq.${enrolmentId}` }, () => router.refresh())
        .subscribe((s) => setStatus(s));
    });
    return () => {
      subscription.unsubscribe();
      if (channel) supabase.removeChannel(channel);
    };
  }, [router, enrolmentId]);

  return <span hidden data-testid="submission-realtime-status" data-status={status} />;
}

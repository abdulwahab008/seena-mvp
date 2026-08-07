'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';

// FR-H04 AC: a newly-published assignment appears without a manual
// refresh. Same auth-token-timing reasoning as admissions' own
// RealtimeEnquiryRefresher (FR-B02) — subscribe only once a session is
// confirmed, via onAuthStateChange rather than a single getSession() call.
// Filtered to this section only; publish_homework() is an UPDATE (status
// draft -> published), not an INSERT, so both events are watched.
export function HomeworkRealtimeRefresher({ sectionId }: { sectionId: string }) {
  const router = useRouter();
  const [status, setStatus] = useState('connecting');

  useEffect(() => {
    const supabase = supabaseBrowser();
    let channel: ReturnType<typeof supabase.channel> | undefined;
    let subscribed = false;

    const {
      data: { subscription: authSubscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!session) return;
      supabase.realtime.setAuth(session.access_token);
      if (subscribed) return;
      subscribed = true;
      channel = supabase
        .channel(`homework-section-${sectionId}`)
        .on(
          'postgres_changes',
          { event: 'INSERT', schema: 'public', table: 'homework', filter: `section_id=eq.${sectionId}` },
          () => router.refresh(),
        )
        .on(
          'postgres_changes',
          { event: 'UPDATE', schema: 'public', table: 'homework', filter: `section_id=eq.${sectionId}` },
          () => router.refresh(),
        )
        .subscribe((subscribeStatus) => setStatus(subscribeStatus));
    });

    return () => {
      authSubscription.unsubscribe();
      if (channel) supabase.removeChannel(channel);
    };
  }, [router, sectionId]);

  return <span hidden data-testid="homework-realtime-status" data-status={status} />;
}

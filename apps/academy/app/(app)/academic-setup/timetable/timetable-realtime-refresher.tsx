'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';

// FR-F04 AC: a co-builder's write to this version's grid shows up in the
// other builder's screen without a reload. Same subscribe-only-after-
// onAuthStateChange pattern as HomeworkRealtimeRefresher (FR-H04) —
// watches INSERT/UPDATE/DELETE since a cell write can be a fresh slot,
// an overwrite of an existing one, or a clear.
export function TimetableRealtimeRefresher({ versionId }: { versionId: string }) {
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
        .channel(`timetable-version-${versionId}`)
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'timetable_slot', filter: `timetable_version_id=eq.${versionId}` },
          () => router.refresh(),
        )
        .subscribe((subscribeStatus) => setStatus(subscribeStatus));
    });

    return () => {
      authSubscription.unsubscribe();
      if (channel) supabase.removeChannel(channel);
    };
  }, [router, versionId]);

  return <span hidden data-testid="timetable-realtime-status" data-status={status} />;
}

'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase/client';

// FR-B02 AC: a new (e.g. public web) enquiry appears in the campus
// admissions queue within 5 seconds, without a manual reload. The
// existing SELECT RLS policy on admission_enquiry already scopes what
// this subscriber receives to their own tenant/campus — Realtime
// enforces the same RLS as any other read.
export function RealtimeEnquiryRefresher() {
  const router = useRouter();
  const [status, setStatus] = useState('connecting');

  useEffect(() => {
    const supabase = supabaseBrowser();
    let channel: ReturnType<typeof supabase.channel> | undefined;
    let subscribed = false;

    // Postgres Changes authorizes each subscriber against RLS using the
    // realtime client's own auth token — @supabase/ssr's browser client
    // restores the session from cookies asynchronously, so subscribing
    // before that resolves (or before a later token refresh) would
    // connect as anon (which, by this FR's own design, can read
    // nothing) rather than the signed-in user. onAuthStateChange fires
    // once synchronously with whatever session already exists (or null)
    // and again on every later change, so it's the one hook that can't
    // race ahead of cookie hydration the way a single getSession() call
    // can.
    const {
      data: { subscription: authSubscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!session) return;
      supabase.realtime.setAuth(session.access_token);
      if (subscribed) return;
      subscribed = true;
      channel = supabase
        .channel('admission-enquiry-inserts')
        .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'admission_enquiry' }, () => {
          router.refresh();
        })
        .subscribe((subscribeStatus) => setStatus(subscribeStatus));
    });

    return () => {
      authSubscription.unsubscribe();
      if (channel) supabase.removeChannel(channel);
    };
  }, [router]);

  return <span hidden data-testid="realtime-status" data-status={status} />;
}

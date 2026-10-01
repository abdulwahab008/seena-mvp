'use client';

import { useEffect, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabase/client';
import { t, type Lang } from '@/lib/i18n/messages';

export type LivePosition = { vehicle_id: string; lat: number; lng: number; speed_kmh: number | null; pinged_at: string };

/**
 * FR-P06: live bus position for the parent. Subscribes to the latest-position
 * table only (never the raw pings). RLS limits the rows to vehicles serving a
 * route the parent's child is allocated to, so another route's bus never arrives
 * on this channel.
 */
export function PositionPanel({ initial, lang }: { initial: LivePosition[]; lang: Lang }) {
  const [rows, setRows] = useState<LivePosition[]>(initial);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const supabase = supabaseBrowser();
    let channel: ReturnType<typeof supabase.channel> | undefined;
    let subscribed = false;
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!session || subscribed) return;
      subscribed = true;
      supabase.realtime.setAuth(session.access_token);
      channel = supabase
        .channel('transport-position')
        .on('postgres_changes', { event: '*', schema: 'public', table: 'transport_vehicle_position_latest' }, (payload) => {
          const next = payload.new as LivePosition | undefined;
          if (!next?.vehicle_id) return;
          setRows((prev) => [...prev.filter((r) => r.vehicle_id !== next.vehicle_id), next]);
        })
        .subscribe();
    });
    const tick = setInterval(() => setNow(Date.now()), 5000);
    return () => {
      subscription.unsubscribe();
      clearInterval(tick);
      if (channel) supabase.removeChannel(channel);
    };
  }, []);

  if (rows.length === 0) return null;
  return (
    <div className="space-y-1 rounded-md border p-3" data-testid="live-position">
      <p className="font-medium">{t(lang, 'transport.live')}</p>
      {rows.map((r) => (
        <p key={r.vehicle_id} className="text-sm">
          {t(lang, 'transport.liveAgo', { s: String(Math.max(0, Math.round((now - Date.parse(r.pinged_at)) / 1000))) })}
          {r.speed_kmh != null ? ` · ${r.speed_kmh} km/h` : ''} ·{' '}
          <a className="underline" href={`https://www.openstreetmap.org/?mlat=${r.lat}&mlon=${r.lng}#map=16/${r.lat}/${r.lng}`} target="_blank" rel="noreferrer">
            {t(lang, 'transport.liveMap')}
          </a>
        </p>
      ))}
    </div>
  );
}

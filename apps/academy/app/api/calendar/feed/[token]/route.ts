import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';

function formatIcsDateTime(dateStr: string, isAllDay: boolean): string {
  const d = new Date(dateStr);
  if (isAllDay) {
    // YYYYMMDD
    return d.toISOString().slice(0, 10).replace(/-/g, '');
  }
  // YYYYMMDDTHHMMSSZ
  return d.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
}

function escapeIcsText(text: string): string {
  if (!text) return '';
  return text
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\n/g, '\\n');
}

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ token: string }> }
) {
  const { token } = await params;

  if (!token || token.trim().length === 0) {
    return new NextResponse('Unauthorized: Missing calendar token', { status: 401 });
  }

  const client = supabaseServiceRole() as any;

  // AC 3: Query guardian ICS events. Throws 42501 if invalid or revoked.
  const { data: events, error } = await client.rpc('get_guardian_ics_events', {
    p_token: token.trim(),
  });

  if (error) {
    // Returns 401 after revocation or if token is invalid
    return new NextResponse('Unauthorized: Invalid or revoked calendar token', {
      status: 401,
      headers: { 'Content-Type': 'text/plain' },
    });
  }

  // Format events as RFC 5545 iCalendar (.ics)
  const lines: string[] = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Seena Academy//Campus Events Calendar//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:Seena Academy Campus Events',
    'X-WR-TIMEZONE:UTC',
  ];

  const nowIcs = formatIcsDateTime(new Date().toISOString(), false);

  for (const ev of events || []) {
    lines.push('BEGIN:VEVENT');
    lines.push(`UID:${ev.event_id}@academy.seena.test`);
    lines.push(`DTSTAMP:${nowIcs}`);

    if (ev.is_all_day) {
      lines.push(`DTSTART;VALUE=DATE:${formatIcsDateTime(ev.starts_at, true)}`);
      // For all-day events, DTEND is exclusive
      const endD = new Date(ev.ends_at);
      endD.setDate(endD.getDate() + 1);
      lines.push(`DTEND;VALUE=DATE:${formatIcsDateTime(endD.toISOString(), true)}`);
    } else {
      lines.push(`DTSTART:${formatIcsDateTime(ev.starts_at, false)}`);
      lines.push(`DTEND:${formatIcsDateTime(ev.ends_at, false)}`);
    }

    const titlePrefix = ev.hijri_label ? `[${ev.hijri_label}] ` : '';
    lines.push(`SUMMARY:${escapeIcsText(titlePrefix + ev.title)}`);

    let desc = ev.description || '';
    if (ev.campus_name) {
      desc += (desc ? ' | ' : '') + `Campus: ${ev.campus_name}`;
    }
    if (desc) {
      lines.push(`DESCRIPTION:${escapeIcsText(desc)}`);
    }

    lines.push(`CATEGORIES:${escapeIcsText(ev.event_type.toUpperCase())}`);
    lines.push('STATUS:CONFIRMED');
    lines.push('END:VEVENT');
  }

  lines.push('END:VCALENDAR');

  return new NextResponse(lines.join('\r\n'), {
    status: 200,
    headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      'Content-Disposition': 'inline; filename="campus_events.ics"',
      'Cache-Control': 'no-cache, no-store, must-revalidate',
    },
  });
}

import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { verifyCronSecret } from '@/lib/comm/cron-auth';

// Queues admissions follow-up and appointment reminders and SMS fallbacks for every tenant, so the
// Reminders page no longer has to be clicked. Scheduled just before the message worker in vercel.json;
// the queued rows reach public.message through the outbound_message trigger and are sent by it.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return run();
}

// Vercel Cron (see vercel.json) sends a GET with the cron secret.
export async function GET(req: NextRequest) {
  if (!verifyCronSecret(req.headers.get('authorization'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return run();
}

async function run() {
  const db = supabaseServiceRole();
  const [followups, appointments, fallbacks] = await Promise.all([
    db.rpc('fn_queue_followup_reminders'),
    db.rpc('fn_queue_appointment_reminders'),
    db.rpc('fn_process_sms_fallbacks'),
  ]);
  const error = followups.error ?? appointments.error ?? fallbacks.error;
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ followups: followups.data, appointments: appointments.data, fallbacks: fallbacks.data });
}

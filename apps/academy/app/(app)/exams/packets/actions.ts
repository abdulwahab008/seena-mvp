'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { packetError, type PacketPlan } from '@/lib/exams/packet-query';
import { renderAndStorePacket, type ReservedPacket } from '@/lib/report-cards/packet';
import { assemblePacketSchema, packetPlanSchema } from '@/lib/validation';

/**
 * FR-J11. Planning a section's packets, and assembling one candidate's.
 *
 * The plan is a single read; assembling is one call per candidate and the
 * board drives them one after another, so a renderer failure on one card is
 * that candidate's line on screen rather than the end of the run.
 */
export type PacketPlanState = { error: string | null; plan?: PacketPlan };
export type AssemblePacketState = {
  error: string | null;
  withChallan?: boolean;
  downloadUrl?: string;
};

const period = (v: string | undefined) => (v ? (v.length === 7 ? `${v}-01` : v) : undefined);

export async function readPacketPlan(input: unknown): Promise<PacketPlanState> {
  const parsed = packetPlanSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_report_card_packet_plan', {
    p_exam_term_id: parsed.data.examTermId,
    p_section_id: parsed.data.sectionId,
    p_billing_period: period(parsed.data.billingPeriod),
  });
  if (error || !data) return { error: error ? packetError(error.message) : 'Could not read the plan.' };
  return { error: null, plan: data as unknown as PacketPlan };
}

export async function assemblePacket(input: unknown): Promise<AssemblePacketState> {
  const parsed = assemblePacketSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('begin_report_card_packet', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_exam_term_id: parsed.data.examTermId,
    p_billing_period: period(parsed.data.billingPeriod),
  });
  if (error || !data) return { error: packetError(error?.message ?? '') };
  const stored = await renderAndStorePacket(supabase, data as unknown as ReservedPacket);
  if (stored.error) return { error: stored.error };
  return { error: null, withChallan: stored.withChallan, downloadUrl: stored.downloadUrl };
}

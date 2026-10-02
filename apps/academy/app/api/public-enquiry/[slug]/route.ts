import { NextResponse, type NextRequest } from 'next/server';
import { createHash } from 'node:crypto';
import { publicEnquirySchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

// FR-B02: the only writer of a web-sourced admission_enquiry row. A real
// HTTP endpoint (not a Server Action, which always answers 200) so the
// AC's own literal "HTTP 429" / "HTTP 404" are real response statuses, not
// just an error string on a 200. submit_public_enquiry() does the actual
// tenant resolution, validation and rate limiting — this route only maps
// its named errors onto status codes and hashes the caller's IP before it
// ever reaches the database.
export async function POST(request: NextRequest, { params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;

  const body = await request.json().catch(() => null);
  const parsed = publicEnquirySchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json({ error: parsed.error.issues[0]?.message ?? 'Invalid input.' }, { status: 400 });
  }

  const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || request.headers.get('x-real-ip') || '0.0.0.0';
  const ipHash = createHash('sha256').update(ip).digest('hex');

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('submit_public_enquiry', {
    p_tenant_slug: slug,
    p_child_name: parsed.data.childName,
    p_child_name_ur: parsed.data.childNameUr || undefined,
    p_dob: parsed.data.dob,
    p_class_code: parsed.data.classCode,
    p_parent_name: parsed.data.parentName,
    p_phone: parsed.data.phone,
    p_whatsapp_opt_in: parsed.data.whatsappOptIn,
    p_ip_hash: ipHash,
  });

  if (error) {
    if (error.message.includes('TENANT_NOT_FOUND')) return NextResponse.json({ error: 'School not found.' }, { status: 404 });
    if (error.message.includes('RATE_LIMIT')) {
      return NextResponse.json({ error: 'Too many attempts. Please try again later.' }, { status: 429 });
    }
    if (error.message.includes('PHONE_INVALID')) return NextResponse.json({ error: 'Enter a valid phone number.' }, { status: 400 });
    if (error.message.includes('CLASS_LEVEL_NOT_FOUND')) return NextResponse.json({ error: 'Choose a valid class.' }, { status: 400 });
    if (error.message.includes('AGE_BELOW_MINIMUM')) {
      return NextResponse.json({ error: 'This child does not yet meet the minimum age for Nursery.' }, { status: 400 });
    }
    if (error.message.includes('CAMPUS_NOT_FOUND') || error.message.includes('SESSION_NOT_FOUND')) {
      return NextResponse.json({ error: 'This school is not currently accepting enquiries.' }, { status: 400 });
    }
    return NextResponse.json({ error: 'Could not submit the enquiry.' }, { status: 400 });
  }

  return NextResponse.json(data, { status: 200 });
}

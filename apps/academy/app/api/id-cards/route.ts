import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { buildIdCardsHtml, ID_CARD_ROLES, type IdCard } from '@/lib/id-cards/html';
import { assetDataUri } from '@/lib/report-cards/render';
import { renderPdf, RendererUnavailableError } from '@/lib/pdf/render';
import { formatDatePk } from '@/lib/dates';

const MAX_CARDS = 500;

const QuerySchema = z.object({
  kind: z.enum(['student', 'staff']),
  campusId: z.string().uuid(),
  sectionId: z.string().uuid().optional(),
  validUntil: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});

export async function GET(req: NextRequest) {
  const q = QuerySchema.safeParse(Object.fromEntries(req.nextUrl.searchParams));
  if (!q.success) return NextResponse.json({ error: 'Invalid card request.' }, { status: 400 });
  const actor = await getCurrentActor();
  if (!actor || !ID_CARD_ROLES.includes(actor.role)) return NextResponse.json({ error: 'Not allowed.' }, { status: 403 });

  const supabase = await supabaseServer();
  const { data: campus } = await supabase.from('campus').select('id, name').eq('id', q.data.campusId).maybeSingle();
  if (!campus) return NextResponse.json({ error: 'Campus not found.' }, { status: 404 });

  let cards: IdCard[];
  if (q.data.kind === 'student') {
    let query = supabase
      .from('enrolment')
      .select('student:student_id(name_en, father_name_en, gr_number, blood_group), class_level:class_level_id(name_en), section:section_id(name)')
      .eq('campus_id', campus.id)
      .eq('status', 'active')
      .limit(MAX_CARDS);
    if (q.data.sectionId) query = query.eq('section_id', q.data.sectionId);
    const { data, error } = await query;
    if (error) return NextResponse.json({ error: 'Could not load students.' }, { status: 500 });
    cards = (data ?? []).flatMap((e) => {
      const s = one(e.student);
      if (!s) return [];
      return [{
        name: s.name_en,
        code: s.gr_number,
        lines: [
          { label: 'Father', value: s.father_name_en },
          { label: 'GR No', value: s.gr_number },
          { label: 'Class', value: [one(e.class_level)?.name_en, one(e.section)?.name].filter(Boolean).join(' ') || null },
          { label: 'Blood group', value: s.blood_group },
        ],
      }];
    });
  } else {
    const { data, error } = await supabase
      .from('staff')
      .select('full_name, employee_code, cnic, designation:designation_id(name_en), department:department_id(name_en)')
      .eq('campus_id', campus.id)
      .eq('employment_status', 'active')
      .order('full_name')
      .limit(MAX_CARDS);
    if (error) return NextResponse.json({ error: 'Could not load staff.' }, { status: 500 });
    cards = (data ?? []).map((s) => ({
      name: s.full_name,
      code: s.employee_code,
      lines: [
        { label: 'Employee No', value: s.employee_code },
        { label: 'Designation', value: one(s.designation)?.name_en ?? null },
        { label: 'Department', value: one(s.department)?.name_en ?? null },
        { label: 'CNIC', value: s.cnic },
      ],
    }));
  }
  if (q.data.kind === 'student') {
    const classOf = (c: IdCard) => c.lines.find((l) => l.label === 'Class')?.value ?? '';
    cards.sort((a, b) => classOf(a).localeCompare(classOf(b), undefined, { numeric: true }) || a.name.localeCompare(b.name));
  }
  if (cards.length === 0) return NextResponse.json({ error: 'Nobody matches these filters.' }, { status: 404 });

  const { data: logo } = await supabase.rpc('resolve_branding', { p_campus_id: campus.id, p_asset_type: 'logo' });
  const logoPath = (logo as { storage_path?: string } | null)?.storage_path ?? null;

  try {
    const pdf = await renderPdf({
      html: buildIdCardsHtml({
        schoolName: campus.name,
        logoDataUri: await assetDataUri(supabase, 'branding', logoPath),
        kindLabel: q.data.kind === 'student' ? 'Student identity card' : 'Staff identity card',
        validUntil: formatDatePk(q.data.validUntil),
        cards,
      }),
      pageFormat: 'A4',
      landscape: false,
    });
    return new NextResponse(new Uint8Array(pdf), {
      headers: {
        'content-type': 'application/pdf',
        'content-disposition': `inline; filename="${q.data.kind}-id-cards.pdf"`,
        'cache-control': 'private, no-store',
      },
    });
  } catch (e) {
    if (e instanceof RendererUnavailableError) return NextResponse.json({ error: 'PDF rendering is unavailable right now.' }, { status: 503 });
    throw e;
  }
}

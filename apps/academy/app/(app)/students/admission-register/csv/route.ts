import { NextRequest, NextResponse } from 'next/server';
import { toCsv } from '@/lib/csv';
import { loadAdmissionRegister, parseRegisterFilters } from '../register';

export async function GET(req: NextRequest) {
  const sp = req.nextUrl.searchParams;
  const { data, error } = await loadAdmissionRegister(parseRegisterFilters({ session: sp.get('session'), class: sp.get('class') }));
  if (error) return NextResponse.json({ error: error.message.includes('FORBIDDEN') ? 'Not allowed.' : 'Could not load the register.' }, { status: error.message.includes('FORBIDDEN') ? 403 : 500 });
  const header = ['GR number', 'Admission date', 'Name', 'Father name', 'Date of birth', 'Class admitted to', 'Session', 'Status', 'Withdrawal date', 'Withdrawal reason'];
  const rows = (data ?? []).map((r) => [r.gr_number, r.admitted_on, r.name_en, r.father_name_en, r.dob, r.class_admitted, r.session_name, r.status, r.withdrawn_on, r.withdrawal_reason]);
  return new NextResponse(toCsv(header, rows), {
    headers: { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="admission-register.csv"', 'cache-control': 'private, no-store' },
  });
}

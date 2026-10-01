import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J11: the report card handed over with next cycle's fee challan.
//
//   AC1  card followed by the 3-copy challan -> a two-page PDF.
//   AC2  no challan for the cycle -> the card alone (one page), and the plan
//        summary counts the affected candidates.
//   AC3  the payable shown is the fee module's amount to the rupee.
//   AC4  a withheld result -> nothing is produced.

const snapshot = (name: string, grNumber: string, renderedAt: string) => ({
  school: { name: 'Packet E2E School', campus_name: 'Main', campus_name_ur: null, campus_code: 'M', city: 'Lahore', address_line: null, phone: null },
  branding: { logo_storage_path: null, letterhead_storage_path: null, signature_storage_path: null, stamp_storage_path: null },
  student: { name_en: name, name_ur: null, father_name_en: 'Father', father_name_ur: null, gr_number: grNumber, roll_no: 1, photo_path: null, class_name: 'Class 1', section_name: 'A' },
  term: { exam_term_id: 'x', code: 'T1', name: 'First Term', name_ur: null, session_name: '2026-27' },
  subjects: [],
  aggregate: { obtained: 0, max_marks: 0, pct: null, grade_label: null, gpa_point: null, is_pass: null },
  grading_scheme: null,
  position: null,
  attendance: { months_counted: 0, present_days: 0, working_days: 0, pct: null, from_date: null, to_date: null },
  remark: null,
  revision_no: 1,
  supersedes_revision: null,
  rendered_at: renderedAt,
});

test('packet = card + challan; card alone without a challan; nothing for a withheld result', async ({ page }) => {
  test.setTimeout(180000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(3, 'packet-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: term } = await db
    .from('exam_term')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, code: 'T1', name: 'First Term', sequence: 1, weight_bp: 10000, counts_toward_annual: true, status: 'active' })
    .select('id')
    .single();

  const { data: enrolments } = await db.from('enrolment').select('id, student:student_id(name_en, gr_number)').in('id', challans.map((c) => c.enrolment_id));
  const info = (enrolments ?? []).map((e) => {
    const s = Array.isArray(e.student) ? e.student[0]! : e.student!;
    return { enrolmentId: e.id, name: s.name_en, gr: s.gr_number };
  });
  const [withChallan, cardOnly, withheld] = info;

  // The card is issued now, in the same month as the seeded (current-cycle) challans, so the
  // "next cycle" is the month after: a fixed date would drift into the past as the calendar moves
  // and turn every current challan into a next-cycle one.
  const cardIssuedAt = new Date().toISOString();
  for (const c of info) {
    const { error } = await db.from('report_card').insert({
      tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, section_id: section!.id, enrolment_id: c.enrolmentId,
      revision_no: 1, storage_path: `${tenant}/${campusId}/${term!.id}/card-${c.enrolmentId}.pdf`, checksum: 'c'.repeat(64),
      status: 'issued', payload_snapshot: snapshot(c.name, c.gr, cardIssuedAt), rendered_at: cardIssuedAt,
    });
    expect(error).toBeNull();
  }

  // The fee module's next-cycle challan for the first student, at a 25% sibling discount;
  // the other two only have the current cycle's, so for them there is nothing next.
  const nextMonth = new Date();
  nextMonth.setUTCMonth(nextMonth.getUTCMonth() + 1, 15);
  const challanOf = (enrolmentId: string) => challans.find((c) => c.enrolment_id === enrolmentId)!;
  const { error: updateError } = await db
    .from('fee_challan')
    .update({ billing_period: nextMonth.toISOString().slice(0, 10), gross_paisa: 1000000, concession_paisa: 250000, net_paisa: 750000 })
    .eq('id', challanOf(withChallan!.enrolmentId).id);
  expect(updateError).toBeNull();
  await db.from('result_withhold').insert({ tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, enrolment_id: withheld!.enrolmentId, reason: 'discipline', cutoff_date: new Date().toISOString().slice(0, 10) });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/packets');
  await page.getByTestId('packet-section-select').selectOption(section!.id);
  await page.getByTestId('open-packets').click();
  await expect(page.getByTestId('packet-plan')).toBeVisible();
  await expect(page.getByTestId('packet-count-with-challan')).toHaveText('1');
  await expect(page.getByTestId('packet-count-card-only')).toHaveText('1');
  await expect(page.getByTestId('packet-count-withheld')).toHaveText('1');
  await expect(page.getByTestId('packet-card-only-summary')).toContainText('no challan for this cycle');
  await expect(page.getByTestId(`packet-payable-${withChallan!.gr}`)).toHaveText('PKR 7,500.00');
  await expect(page.getByTestId(`packet-status-${withheld!.gr}`)).toContainText('withheld');
  await expect(page.getByTestId(`assemble-${withheld!.gr}`)).toHaveCount(0);

  await page.getByTestId('assemble-all').click();
  await expect(page.getByTestId(`packet-download-${withChallan!.gr}`)).toBeVisible({ timeout: 90000 });
  await expect(page.getByTestId(`packet-download-${cardOnly!.gr}`)).toBeVisible({ timeout: 90000 });
  await expect(page.getByTestId(`packet-download-${withheld!.gr}`)).toHaveCount(0);

  const pages = (bytes: Buffer) => (bytes.toString('latin1').match(/\/Type\s*\/Page[^s]/g) ?? []).length;
  const get = async (gr: string) => {
    const href = await page.getByTestId(`packet-download-${gr}`).getAttribute('href');
    const res = await page.request.get(href!);
    expect(res.status()).toBe(200);
    const body = await res.body();
    expect(body.subarray(0, 4).toString()).toBe('%PDF');
    return body;
  };
  expect(pages(await get(withChallan!.gr))).toBe(2);
  expect(pages(await get(cardOnly!.gr))).toBe(1);

  const { data: packets } = await db.from('report_card_packet').select('enrolment_id, challan_id, payable_paisa').eq('exam_term_id', term!.id);
  expect(packets).toHaveLength(2);
  const mine = packets!.find((p) => p.enrolment_id === withChallan!.enrolmentId)!;
  expect(mine.payable_paisa).toBe(750000);
  expect(packets!.find((p) => p.enrolment_id === cardOnly!.enrolmentId)!.challan_id).toBeNull();
  expect(packets!.some((p) => p.enrolment_id === withheld!.enrolmentId)).toBe(false);
});

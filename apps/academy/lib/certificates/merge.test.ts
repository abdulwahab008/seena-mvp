import { describe, expect, it } from 'vitest';
import { applyMergeFields, extractMergeFields, validateMergeFields, type CatalogField } from './merge';

// The catalogue rows these tests run against mirror
// public.certificate_type_field_catalog for 'transfer'. student.blood_group
// is deliberately absent — it is a real student column and an unreal merge
// field, which is exactly AC1's case.
const TRANSFER_CATALOG: CatalogField[] = [
  { field_path: 'student.name_en', required: true, label_en: 'Student name' },
  { field_path: 'student.gr_number', required: true, label_en: 'GR number' },
  { field_path: 'issue.date', required: true, label_en: 'Date of issue' },
  { field_path: 'issue.serial_no', required: true, label_en: 'Certificate serial no.' },
  { field_path: 'enrolment.left_on', required: true, label_en: 'Date of leaving' },
  { field_path: 'transfer.conduct', required: false, label_en: 'Conduct' },
];

const COMPLETE_BODY =
  '<p>{{student.name_en}} ({{student.gr_number}}) serial {{issue.serial_no}} issued {{issue.date}} left {{enrolment.left_on}}</p>';

describe('extractMergeFields', () => {
  it('extracts, trims and de-duplicates the tokens a body references', () => {
    expect(extractMergeFields('<p>{{student.name_en}} of {{ enrolment.class_name }} — {{student.name_en}}</p>')).toEqual([
      'enrolment.class_name',
      'student.name_en',
    ]);
  });

  it('returns nothing for a body with no merge fields', () => {
    expect(extractMergeFields('<p>This is to certify that the bearer studied here.</p>')).toEqual([]);
  });

  it('extracts a malformed token too, so validation can reject it rather than print it', () => {
    expect(extractMergeFields('<p>{{ student name }}</p>')).toEqual(['student name']);
    expect(extractMergeFields('<p>{{}}</p>')).toEqual(['']);
  });

  it('is not confused by a single brace or an unclosed token', () => {
    expect(extractMergeFields('<p>{student.name_en} and {{unclosed</p>')).toEqual([]);
  });
});

describe('validateMergeFields', () => {
  it('AC1: names the field that is not in the whitelist', () => {
    const report = validateMergeFields(
      `<p>{{student.name_en}} ({{student.gr_number}}) blood group {{student.blood_group}} serial {{issue.serial_no}} issued {{issue.date}} left {{enrolment.left_on}}</p>`,
      TRANSFER_CATALOG,
    );
    expect(report.unknown).toEqual(['student.blood_group']);
    expect(report.ok).toBe(false);
  });

  it('lists every statutory field a document of this type is missing', () => {
    const report = validateMergeFields('<p>{{student.name_en}} has left.</p>', TRANSFER_CATALOG);
    expect(report.missingRequired).toEqual(['enrolment.left_on', 'issue.date', 'issue.serial_no', 'student.gr_number']);
    expect(report.ok).toBe(false);
  });

  it('passes a body that uses only catalogued fields and every required one', () => {
    const report = validateMergeFields(COMPLETE_BODY, TRANSFER_CATALOG);
    expect(report.unknown).toEqual([]);
    expect(report.missingRequired).toEqual([]);
    expect(report.used).toEqual([
      'enrolment.left_on',
      'issue.date',
      'issue.serial_no',
      'student.gr_number',
      'student.name_en',
    ]);
    expect(report.ok).toBe(true);
  });

  it('does not require optional fields', () => {
    expect(validateMergeFields(COMPLETE_BODY, TRANSFER_CATALOG).missingRequired).not.toContain('transfer.conduct');
  });
});

describe('applyMergeFields', () => {
  it('substitutes values and leaves the authored markup alone', () => {
    expect(applyMergeFields('<p><b>{{student.name_en}}</b> — {{issue.date}}</p>', {
      'student.name_en': 'Ahmed Raza',
      'issue.date': '12 August 2026',
    })).toBe('<p><b>Ahmed Raza</b> — 12 August 2026</p>');
  });

  it('tolerates whitespace inside the token, as the extractor does', () => {
    expect(applyMergeFields('<p>{{  student.name_en  }}</p>', { 'student.name_en': 'Ahmed Raza' })).toBe('<p>Ahmed Raza</p>');
  });

  it('escapes the substituted value so a student record cannot rewrite the document', () => {
    expect(applyMergeFields('<p>{{student.name_en}}</p>', { 'student.name_en': '<script>x</script> & "co"' })).toBe(
      '<p>&lt;script&gt;x&lt;/script&gt; &amp; &quot;co&quot;</p>',
    );
  });

  it('renders an unresolved field visibly rather than as a silent gap', () => {
    expect(applyMergeFields('<p>{{issue.serial_no}}</p>', {})).toBe('<p>[issue.serial_no]</p>');
  });

  it('substitutes Urdu values unchanged', () => {
    expect(applyMergeFields('<p>{{student.name_ur}}</p>', { 'student.name_ur': 'احمد رضا' })).toBe('<p>احمد رضا</p>');
  });
});

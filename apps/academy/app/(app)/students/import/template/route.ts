import { buildStudentImportTemplateCsv } from '@/lib/student-import';

// FR-C14 AC: the header-mismatch message links here, so a Principal whose
// file was rejected can download the exact column set the importer wants.
export function GET() {
  return new Response(buildStudentImportTemplateCsv(), {
    headers: {
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': 'attachment; filename="student-import-template.csv"',
    },
  });
}

import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { certificateDownloadPath } from '@/lib/certificates/issue';
import { formatDatePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const DOCUMENTS = [
  { href: '/certificates/issue', label: 'Transfer certificate' },
  { href: '/certificates/issue/character', label: 'Character certificate' },
  { href: '/certificates/issue/leaving', label: 'School leaving certificate' },
  { href: '/certificates/requests', label: 'Bonafide certificate' },
  { href: '/students/reports/admission-form', label: 'Admission form' },
  { href: '/id-cards', label: 'Student ID card' },
];
const TYPE_LABEL = { transfer: 'Transfer', character: 'Character', leaving: 'Leaving', bonafide: 'Bonafide' } as const;
const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;

export default async function StudentDocumentsPage({ searchParams }: { searchParams: Promise<{ type?: string }> }) {
  const { type } = await searchParams;
  const supabase = await supabaseServer();
  let query = supabase
    .from('certificate_issue')
    .select('id, serial_no, certificate_type, status, issued_at, student:student_id(id, name_en, gr_number)')
    .order('issued_at', { ascending: false })
    .limit(100);
  if (type && type in TYPE_LABEL) query = query.eq('certificate_type', type as keyof typeof TYPE_LABEL);
  const { data: issued } = await query;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Student documents</h1>
        <p className="text-sm text-muted-foreground">Issue certificates and forms, and find every document already issued.</p>
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-12">#</TableHead>
            <TableHead>Issue a document</TableHead>
            <TableHead className="w-24 text-right" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {DOCUMENTS.map((d, i) => (
            <TableRow key={d.href} data-testid="document-row">
              <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
              <TableCell>{d.label}</TableCell>
              <TableCell className="text-right">
                <Link href={d.href} className="text-sm font-medium text-primary hover:underline">
                  Issue
                </Link>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>

      <section className="space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-lg font-semibold">Issued documents</h2>
          <form method="get" className="flex gap-2 text-sm">
            <select name="type" defaultValue={type ?? ''} aria-label="Document type" className="h-9 rounded-md border bg-background px-2">
              <option value="">All types</option>
              {Object.entries(TYPE_LABEL).map(([k, label]) => (
                <option key={k} value={k}>
                  {label}
                </option>
              ))}
            </select>
            <button type="submit" className="h-9 rounded-md border px-3">
              Show
            </button>
          </form>
        </div>
        {(issued ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No documents issued yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Serial</TableHead>
                <TableHead>Document</TableHead>
                <TableHead>Student</TableHead>
                <TableHead>Issued</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {(issued ?? []).map((r) => {
                const s = one(r.student);
                return (
                  <TableRow key={r.id} data-testid="issued-row">
                    <TableCell className="tabular font-mono">{r.serial_no}</TableCell>
                    <TableCell>{TYPE_LABEL[r.certificate_type]}</TableCell>
                    <TableCell>
                      {s && (
                        <Link href={`/students/${s.id}`} className="hover:underline">
                          {s.name_en} <span className="text-muted-foreground">({s.gr_number})</span>
                        </Link>
                      )}
                    </TableCell>
                    <TableCell>{formatDatePk(r.issued_at.slice(0, 10))}</TableCell>
                    <TableCell>
                      <Badge variant={r.status === 'issued' ? 'success' : 'destructive'}>{r.status}</Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      {r.status === 'issued' && (
                        <a href={certificateDownloadPath(r.id)} className="text-sm font-medium text-primary hover:underline">
                          Download
                        </a>
                      )}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </section>
    </div>
  );
}

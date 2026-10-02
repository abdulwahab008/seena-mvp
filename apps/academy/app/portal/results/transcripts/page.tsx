import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';

/**
 * FR-J13 for parents: the cumulative transcripts the school has issued for
 * their child. transcript_issue's parent policy shows only an issued
 * (sealed) transcript, and the download route re-checks its digest.
 */
export default async function PortalTranscriptsPage() {
  const supabase = await supabaseServer();
  const { data: issued } = await supabase
    .from('transcript_issue')
    .select('id, serial_no, purpose, issued_on, student:student_id(name_en)')
    .eq('status', 'issued')
    .order('issued_at', { ascending: false });

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Transcripts</h2>
        <p className="text-sm text-muted-foreground">
          FR-J13 — transcripts the school has issued for your child.{' '}
          <Link href="/portal/results" className="underline">
            Back to results
          </Link>
        </p>
      </div>
      {(issued ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground" data-testid="portal-transcripts-empty">
          No transcript has been issued yet.
        </p>
      ) : (
        <ul className="space-y-2 text-sm" data-testid="portal-transcripts">
          {(issued ?? []).map((i) => (
            <li key={i.id} className="flex items-center justify-between gap-3 rounded-md border p-3">
              <span>
                <span className="font-mono">{i.serial_no}</span> · {(Array.isArray(i.student) ? i.student[0] : i.student)?.name_en} · {i.purpose} · {i.issued_on}
              </span>
              <a href={`/api/transcripts/${i.id}/download`} className="underline" data-testid={`portal-transcript-${i.serial_no}`}>
                Download
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

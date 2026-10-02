import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { UploadForm, ProfileForm } from './bank-forms';

export default async function BankStatementsPage() {
  const supabase = await supabaseServer();
  const [accountsRes, importsRes] = await Promise.all([
    supabase.from('campus_bank_account').select('id, bank_name, title, account_no, mapping_profile_id').order('bank_name'),
    supabase
      .from('bank_statement_import')
      .select('id, file_name, row_count, parsed_count, failed_count, status, created_at')
      .order('created_at', { ascending: false })
      .limit(30),
  ]);
  const accounts = (accountsRes.data ?? []).map((a) => ({ id: a.id, label: `${a.bank_name} · ${a.title} · ${a.account_no}`, hasProfile: Boolean(a.mapping_profile_id) }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Bank statements</h1>
        <p className="text-sm text-muted-foreground">
          FR-K19 — upload the bank&apos;s collection scroll (CSV). Each file can be imported once per account; unreadable rows are kept for review.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Upload a statement</CardTitle>
        </CardHeader>
        <CardContent>
          <UploadForm accounts={accounts} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Column mapping profile</CardTitle>
        </CardHeader>
        <CardContent>
          <ProfileForm accounts={accounts} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Recent imports</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm">
          {(importsRes.data ?? []).length === 0 && <p className="text-muted-foreground">No statements imported yet.</p>}
          {(importsRes.data ?? []).map((i) => (
            <div key={i.id} className="flex justify-between border-b py-1" data-testid="bank-import-row">
              <Link href={`/fees/bank-statements/${i.id}`} className="underline-offset-2 hover:underline">
                {i.file_name ?? 'statement'} — {i.parsed_count} parsed, {i.failed_count} failed of {i.row_count}
              </Link>
              <span className="text-muted-foreground">
                {i.status} · {new Date(i.created_at).toLocaleDateString()}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

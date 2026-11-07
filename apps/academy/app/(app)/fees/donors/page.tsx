import { supabaseServer } from '@/lib/supabase/server';
import { formatPkr } from '@/lib/challan/html';
import { formatDatePk } from '@/lib/dates';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { ApplySponsorships, DonationForm, DonorForm, EndSponsorship, SponsorshipForm } from './donor-forms';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function DonorsPage() {
  const supabase = await supabaseServer();
  const [{ data: donors }, { data: donations }, { data: sponsorships }] = await Promise.all([
    supabase.from('donor').select('id, name, phone, donation(amount_paisa)').order('name'),
    supabase.from('donation').select('id, amount_paisa, received_on, mode, purpose, reference, donor(name)').order('received_on', { ascending: false }).limit(50),
    supabase.from('sponsorship').select('id, monthly_paisa, donor(name), student(name_en, gr_number), sponsorship_payment(amount_paisa)').eq('is_active', true),
  ]);
  const donorOptions = (donors ?? []).map((d) => ({ id: d.id, label: d.name }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Donors and sponsorships</h1>
        <p className="text-sm text-muted-foreground">
          Record donations, and let a donor sponsor a student&apos;s fees each month. Paying sponsored fees records a normal fee payment against the student&apos;s open challans, once per month, so receipts and the ledger match.
        </p>
      </div>
      <div className="grid gap-6 lg:grid-cols-[1fr_20rem]">
        <div className="space-y-6">
          <section className="space-y-2">
            <div className="flex flex-wrap items-end justify-between gap-2">
              <h2 className="font-medium">Active sponsorships</h2>
              <ApplySponsorships />
            </div>
            {(sponsorships ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">No sponsorships yet.</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Student</TableHead>
                    <TableHead>Sponsor</TableHead>
                    <TableHead className="text-right">Monthly</TableHead>
                    <TableHead className="text-right">Paid so far</TableHead>
                    <TableHead />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(sponsorships ?? []).map((s) => {
                    const st = one(s.student);
                    return (
                      <TableRow key={s.id} data-testid="sponsorship-row">
                        <TableCell>
                          {st?.name_en} <span className="text-xs text-muted-foreground">{st?.gr_number}</span>
                        </TableCell>
                        <TableCell>{one(s.donor)?.name}</TableCell>
                        <TableCell className="text-right">{formatPkr(s.monthly_paisa)}</TableCell>
                        <TableCell className="text-right">{formatPkr((s.sponsorship_payment ?? []).reduce((n, p) => n + p.amount_paisa, 0))}</TableCell>
                        <TableCell className="text-right">
                          <EndSponsorship id={s.id} />
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            )}
          </section>
          {donorOptions.length > 0 && <SponsorshipForm donors={donorOptions} />}
          {donorOptions.length > 0 && <DonationForm donors={donorOptions} />}
          <section className="space-y-2">
            <h2 className="font-medium">Recent donations</h2>
            {(donations ?? []).length === 0 ? (
              <p className="text-sm text-muted-foreground">No donations recorded yet.</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Date</TableHead>
                    <TableHead>Donor</TableHead>
                    <TableHead>Purpose</TableHead>
                    <TableHead>Mode</TableHead>
                    <TableHead className="text-right">Amount</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(donations ?? []).map((d) => (
                    <TableRow key={d.id} data-testid="donation-row">
                      <TableCell>{formatDatePk(d.received_on)}</TableCell>
                      <TableCell>{one(d.donor)?.name}</TableCell>
                      <TableCell className="capitalize">{d.purpose}</TableCell>
                      <TableCell className="capitalize">{d.mode}</TableCell>
                      <TableCell className="text-right">{formatPkr(d.amount_paisa)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </section>
        </div>
        <div className="space-y-6">
          <DonorForm />
          {(donors ?? []).length > 0 && (
            <section className="space-y-1 text-sm">
              <h2 className="font-medium">Donors</h2>
              {(donors ?? []).map((d) => (
                <p key={d.id} className="flex justify-between gap-2">
                  <span>{d.name}</span>
                  <span className="text-muted-foreground">{formatPkr((d.donation ?? []).reduce((n, x) => n + x.amount_paisa, 0))}</span>
                </p>
              ))}
            </section>
          )}
        </div>
      </div>
    </div>
  );
}

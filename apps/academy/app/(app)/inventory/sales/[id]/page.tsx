import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { pkr } from '@/lib/rpc-action';
import { PrintButton } from './print-button';

type Receipt = {
  serial: string;
  doc_type: 'sale' | 'credit_note';
  sold_at: string;
  settlement: 'cash' | 'fee_ledger';
  total_paisa: number;
  student: { gr_number: string; name: string; class: string | null };
  lines: { item_id: string; item_code: string; name: string; size: string | null; qty: number; unit_price_paisa: number; amount_paisa: number; from_package: boolean }[];
};

export default async function ReceiptPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('get_sale_receipt', { p_sale_id: id });
  if (error || !data) notFound();
  const r = data as unknown as Receipt;
  return (
    <div className="mx-auto max-w-xl space-y-4">
      <Card data-testid="receipt">
        <CardHeader>
          <CardTitle className="flex items-center justify-between text-base">
            <span>{r.doc_type === 'credit_note' ? 'Credit note' : 'Sale receipt'}</span>
            <span className="font-mono" data-testid="receipt-serial">
              {r.serial}
            </span>
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          <div data-testid="receipt-student">
            <p>
              {r.student.name} · GR {r.student.gr_number}
            </p>
            <p className="text-muted-foreground">
              Class {r.student.class ?? '—'} · {new Date(r.sold_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })} · {r.settlement === 'cash' ? 'Cash' : 'Charged to fee'}
            </p>
          </div>
          <table className="w-full">
            <tbody>
              {r.lines.map((l) => (
                <tr key={l.item_id} className="border-t">
                  <td className="py-1">
                    {l.name}
                    {l.size ? ` (${l.size})` : ''}
                    {l.from_package ? ' · from admission package' : ''}
                  </td>
                  <td className="text-right">
                    {Number(l.qty)} × {pkr(l.unit_price_paisa)}
                  </td>
                  <td className="text-right">{pkr(l.amount_paisa)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="text-right text-base font-semibold" data-testid="receipt-total">
            Total {pkr(r.total_paisa)}
          </p>
        </CardContent>
      </Card>
      <PrintButton />
    </div>
  );
}

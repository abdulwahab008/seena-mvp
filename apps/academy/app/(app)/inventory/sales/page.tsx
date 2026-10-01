import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { ActionForm } from '@/components/action-form';
import { pkr } from '@/lib/rpc-action';
import { SaleForm, type SaleItem } from './sale-form';
import { returnItemAction } from './actions';

type SearchParams = { gr?: string };

export default async function SalesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const gr = (sp.gr ?? '').trim();

  const { data: student } = gr
    ? await supabase.from('student').select('id, name_en, gr_number').eq('gr_number', gr).maybeSingle()
    : { data: null };

  let items: SaleItem[] = [];
  if (student) {
    const [{ data: catalogue }, { data: context }] = await Promise.all([
      supabase.from('inv_item').select('id, item_code, name, size, sale_price').eq('active', true).order('item_code'),
      supabase.rpc('get_sale_context', { p_student_id: student.id }),
    ]);
    const pkg = new Map(((context as { package?: { item_id: string; remaining: number }[] } | null)?.package ?? []).map((p) => [p.item_id, Number(p.remaining)]));
    items = (catalogue ?? []).map((i) => ({ id: i.id, code: i.item_code, name: i.name, size: i.size, pricePaisa: Number(i.sale_price), packageRemaining: pkg.get(i.id) ?? 0 }));
  }

  const [{ data: sales }, { data: allItems }] = await Promise.all([
    supabase.from('inv_sale').select('id, serial, doc_type, settlement, total, sold_at, student_name, student_gr').order('sold_at', { ascending: false }).limit(25),
    supabase.from('inv_item').select('id, item_code, name').order('item_code'),
  ]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Counter sales"
        description="FR-R02 — sell uniforms and books against the student. Cash goes on the cash book; charge-to-fee goes on the student's next challan under UNIFORM_BOOKS. Receipts are numbered without gaps and are never edited; a return is a credit note."
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">New sale</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <form method="get" className="flex items-end gap-2 text-sm">
            <label className="space-y-1">
              <span className="block text-muted-foreground">GR number</span>
              <input name="gr" defaultValue={gr} className="h-9 rounded-md border bg-background px-2" />
            </label>
            <button type="submit" className="h-9 rounded-md border px-3" data-testid="find-student">
              Find student
            </button>
          </form>
          {gr && !student && <p className="text-sm text-muted-foreground">No student with that GR number at your campus.</p>}
          {student && (
            <div className="space-y-3">
              <p className="text-sm" data-testid="sale-student">
                {student.name_en} · GR {student.gr_number}
              </p>
              {items.some((i) => i.packageRemaining > 0) && (
                <p className="rounded-md border border-dashed p-2 text-sm" data-testid="package-notice">
                  The admission package already covers: {items.filter((i) => i.packageRemaining > 0).map((i) => `${i.name} × ${i.packageRemaining}`).join(', ')}. Issue these from the package rather than selling them again.
                </p>
              )}
              <SaleForm studentId={student.id} items={items} />
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Return an item</CardTitle>
        </CardHeader>
        <CardContent>
          <ActionForm
            testId="return-form"
            submitLabel="Issue credit note"
            action={returnItemAction}
            fields={[
              { name: 'saleId', label: 'Receipt', type: 'select', required: true, options: (sales ?? []).filter((s) => s.doc_type === 'sale').map((s) => ({ value: s.id, label: `${s.serial} · ${s.student_name}` })) },
              { name: 'itemId', label: 'Item', type: 'select', required: true, options: (allItems ?? []).map((i) => ({ value: i.id, label: `${i.item_code} · ${i.name}` })) },
              { name: 'qty', label: 'Quantity', type: 'number', defaultValue: '1' },
            ]}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Recent receipts</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto text-sm" data-testid="receipt-list">
          {(sales ?? []).length === 0 && <p className="text-muted-foreground">No sales yet.</p>}
          {(sales ?? []).map((s) => (
            <div key={s.id} className="flex items-center justify-between gap-3 border-b py-2" data-testid="receipt-row">
              <Link href={`/inventory/sales/${s.id}`} className="font-mono underline">
                {s.serial}
              </Link>
              <span>
                {s.student_name} · {s.student_gr}
              </span>
              <span className="flex items-center gap-2">
                <Badge variant="outline">{s.doc_type === 'credit_note' ? 'Credit note' : s.settlement === 'cash' ? 'Cash' : 'Charge to fee'}</Badge>
                {pkr(s.total)}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

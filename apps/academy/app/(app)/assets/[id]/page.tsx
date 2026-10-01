import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { pkr } from '@/lib/rpc-action';

export default async function AssetLedgerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: asset } = await supabase
    .from('v_asset_register')
    .select('asset_id, tag_no, name, category, purchased_on, capitalised_cost, useful_life_months, salvage_value, method, rate, status, accumulated_depreciation, net_book_value')
    .eq('asset_id', id)
    .maybeSingle();
  if (!asset) notFound();
  const { data: entries } = await supabase.from('asset_depreciation_entry').select('period, amount, opening_wdv, closing_wdv').eq('asset_id', id).order('period', { ascending: false }).limit(120);

  return (
    <div className="space-y-6">
      <PageHeader title={`${asset.tag_no} · ${asset.name}`} description={`${asset.category} · purchased ${asset.purchased_on} · ${asset.method === 'SL' ? `straight line over ${asset.useful_life_months} months` : `reducing balance at ${asset.rate}% a year`}`} />

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center justify-between text-base">
            <span>Asset ledger</span>
            <Badge variant={asset.status === 'active' ? 'success' : 'outline'}>{(asset.status ?? '').replace('_', ' ')}</Badge>
          </CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3 text-sm sm:grid-cols-4" data-testid="asset-ledger">
          <div>
            <p className="text-muted-foreground">Capitalised cost</p>
            <p data-testid="ledger-cost" className="font-medium">
              {pkr(asset.capitalised_cost)}
            </p>
          </div>
          <div>
            <p className="text-muted-foreground">Accumulated depreciation</p>
            <p className="font-medium">{pkr(asset.accumulated_depreciation)}</p>
          </div>
          <div>
            <p className="text-muted-foreground">Net book value</p>
            <p data-testid="ledger-nbv" className="font-medium">
              {pkr(asset.net_book_value)}
            </p>
          </div>
          <div>
            <p className="text-muted-foreground">Salvage value</p>
            <p className="font-medium">{pkr(asset.salvage_value)}</p>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Depreciation schedule</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto text-sm">
          <table className="w-full">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Period</th>
                <th className="text-right">Opening</th>
                <th className="text-right">Depreciation</th>
                <th className="text-right">Closing</th>
              </tr>
            </thead>
            <tbody>
              {(entries ?? []).map((e) => (
                <tr key={e.period} className="border-t" data-testid="dep-row">
                  <td className="py-1">{e.period.slice(0, 7)}</td>
                  <td className="text-right">{pkr(e.opening_wdv)}</td>
                  <td className="text-right">{pkr(e.amount)}</td>
                  <td className="text-right">{pkr(e.closing_wdv)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {(entries ?? []).length === 0 && <p className="text-muted-foreground">No depreciation has been posted yet.</p>}
        </CardContent>
      </Card>
    </div>
  );
}

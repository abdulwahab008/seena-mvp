import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PageHeader } from '@/components/ui/page-header';
import { ActionForm } from '@/components/action-form';
import { pkr } from '@/lib/rpc-action';
import { createAssetAction, disposeAssetAction, runDepreciationAction } from './actions';

export default async function AssetsPage() {
  const supabase = await supabaseServer();
  const [{ data: assets }, { data: campuses }] = await Promise.all([
    supabase
      .from('v_asset_register')
      .select('asset_id, tag_no, name, category, capitalised_cost, accumulated_depreciation, net_book_value, status, method, campus_id')
      .order('tag_no'),
    supabase.from('campus').select('id, name').order('name'),
  ]);
  const live = (assets ?? []).filter((a) => a.status === 'active' || a.status === 'in_repair');
  const monthDefault = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' }).slice(0, 7);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Asset register"
        description="FR-R03 — every capitalised asset has a tag and depreciates itself monthly (straight line or reducing balance). The final instalment is the remainder, so net book value ends at exactly the salvage value. Running a month twice posts nothing."
      />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Assets</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto text-sm">
          <table className="w-full" data-testid="asset-table">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1 pr-3">Tag</th>
                <th className="pr-3">Name</th>
                <th className="pr-3">Method</th>
                <th className="pr-3 text-right">Cost</th>
                <th className="pr-3 text-right">Accumulated</th>
                <th className="pr-3 text-right">Net book value</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {(assets ?? []).map((a) => (
                <tr key={a.asset_id} className="border-t" data-testid="asset-row">
                  <td className="py-1 pr-3 font-mono">
                    <Link href={`/assets/${a.asset_id}`} className="underline">
                      {a.tag_no}
                    </Link>
                  </td>
                  <td className="pr-3">{a.name}</td>
                  <td className="pr-3">{a.method === 'SL' ? 'Straight line' : 'Reducing balance'}</td>
                  <td className="pr-3 text-right">{pkr(a.capitalised_cost)}</td>
                  <td className="pr-3 text-right">{pkr(a.accumulated_depreciation)}</td>
                  <td className="pr-3 text-right" data-testid={`nbv-${a.tag_no}`}>
                    {pkr(a.net_book_value)}
                  </td>
                  <td>
                    <Badge variant={a.status === 'active' ? 'success' : 'outline'}>{(a.status ?? '').replace('_', ' ')}</Badge>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {(assets ?? []).length === 0 && <p className="text-muted-foreground">No assets registered yet.</p>}
        </CardContent>
      </Card>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Register an asset</CardTitle>
          </CardHeader>
          <CardContent>
            <ActionForm
              testId="asset-form"
              submitLabel="Register asset"
              action={createAssetAction}
              fields={[
                { name: 'campusId', label: 'Campus', type: 'select', required: true, options: (campuses ?? []).map((c) => ({ value: c.id, label: c.name })) },
                { name: 'tagNo', label: 'Tag number' },
                { name: 'name', label: 'Name' },
                { name: 'category', label: 'Category', type: 'select', required: true, options: ['furniture', 'it', 'lab', 'vehicle', 'building', 'other'].map((c) => ({ value: c, label: c })) },
                { name: 'purchasedOn', label: 'Purchased on', type: 'date' },
                { name: 'costPkr', label: 'Capitalised cost (PKR)', type: 'number' },
                { name: 'lifeMonths', label: 'Useful life (months)', type: 'number' },
                { name: 'salvagePkr', label: 'Salvage value (PKR)', type: 'number', defaultValue: '0' },
                { name: 'method', label: 'Method', type: 'select', required: true, defaultValue: 'SL', options: [{ value: 'SL', label: 'Straight line' }, { value: 'RB', label: 'Reducing balance' }] },
                { name: 'rate', label: 'Annual rate % (reducing balance)', type: 'number' },
              ]}
            />
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Run monthly depreciation</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="dep-form"
                submitLabel="Run depreciation"
                action={runDepreciationAction}
                resetOnSuccess={false}
                fields={[{ name: 'period', label: 'Month (YYYY-MM)', defaultValue: monthDefault }]}
              />
              <p className="mt-2 text-xs text-muted-foreground">Also runs automatically on the 2nd of each month for the month just closed.</p>
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Dispose of an asset</CardTitle>
            </CardHeader>
            <CardContent>
              <ActionForm
                testId="dispose-form"
                submitLabel="Dispose"
                action={disposeAssetAction}
                fields={[
                  { name: 'assetId', label: 'Asset', type: 'select', required: true, options: live.map((a) => ({ value: a.asset_id ?? '', label: `${a.tag_no} · ${a.name}` })) },
                  { name: 'disposedOn', label: 'Disposed on', type: 'date' },
                  { name: 'proceedsPkr', label: 'Sale proceeds (PKR)', type: 'number', defaultValue: '0' },
                  { name: 'writeOff', label: 'Write off (no proceeds)', type: 'checkbox' },
                ]}
              />
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}

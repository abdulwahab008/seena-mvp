import { supabaseServer } from '@/lib/supabase/server';
import { getLang } from '@/lib/i18n/server';
import { t } from '@/lib/i18n/messages';
import { formatDatePk } from '@/lib/dates';

const CATEGORY: Record<string, string> = { syllabus: 'Syllabus', material: 'Study material', other: 'Other' };

export default async function PortalDownloadsPage() {
  const lang = await getLang();
  const supabase = await supabaseServer();
  const { data: items } = await supabase.rpc('portal_download_items');

  return (
    <div className="space-y-6">
      <h2 className="text-2xl font-semibold">{t(lang, 'downloads.title')}</h2>
      {(items ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">{t(lang, 'downloads.empty')}</p>
      ) : (
        <ul className="divide-y rounded-md border">
          {(items ?? []).map((d) => (
            <li key={d.id} className="flex items-center justify-between gap-3 p-3">
              <div>
                <p className="font-medium">{d.title}</p>
                <p className="text-xs text-muted-foreground">
                  {CATEGORY[d.category] ?? d.category} · {formatDatePk(d.created_at)}
                </p>
              </div>
              <a href={`/api/downloads/${d.id}`} className="text-sm font-medium text-primary underline" data-testid="portal-download">
                {d.original_filename}
              </a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

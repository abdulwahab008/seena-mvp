import { supabaseServer } from '@/lib/supabase/server';

export const metadata = {
  title: 'School Circulars | Parent Portal',
};

export default async function PortalCircularsPage() {
  const supabase = await supabaseServer();

  const client = supabase as any;

  // Queries circular table directly - RLS enforces status = 'published' AND publish_at <= now()
  // AND matches child's enrolled class/segment
  const { data: circulars, error } = await client
    .from('circular')
    .select(`
      id,
      title,
      body_en,
      body_ur,
      publish_at,
      expires_at,
      created_at,
      circular_attachment (
        id,
        file_name,
        mime_type,
        size_bytes,
        storage_path
      )
    `)
    .order('publish_at', { ascending: false });

  const activeCirculars = circulars || [];

  return (
    <div className="space-y-6">
      <div className="border-b pb-4">
        <h2 className="text-xl font-bold tracking-tight text-foreground">Official School Circulars</h2>
        <p className="text-sm text-muted-foreground">
          View official school notices, announcements, and attached documents for your enrolled children.
        </p>
      </div>

      {activeCirculars.length === 0 ? (
        <div className="p-8 text-center rounded-lg border bg-card text-muted-foreground">
          <p className="text-sm font-medium">No circulars or notices available at this time.</p>
        </div>
      ) : (
        <div className="space-y-4">
          {activeCirculars.map((circ: any) => (
            <div
              key={circ.id}
              className="p-5 rounded-lg border bg-card text-card-foreground shadow-sm space-y-3"
            >
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-1 border-b pb-2">
                <h3 className="font-semibold text-base text-foreground">{circ.title}</h3>
                <span className="text-xs text-muted-foreground">
                  Published: {new Date(circ.publish_at).toLocaleDateString([], {
                    year: 'numeric',
                    month: 'short',
                    day: 'numeric',
                  })}
                </span>
              </div>

              {circ.body_en && (
                <p className="text-sm text-foreground whitespace-pre-line">{circ.body_en}</p>
              )}

              {circ.body_ur && (
                <p
                  className="text-sm text-foreground whitespace-pre-line font-arabic bg-muted/30 p-3 rounded"
                  dir="rtl"
                >
                  {circ.body_ur}
                </p>
              )}

              {circ.circular_attachment && circ.circular_attachment.length > 0 && (
                <div className="border-t pt-2 mt-2">
                  <span className="text-xs font-semibold text-muted-foreground uppercase tracking-wider block mb-2">
                    Attachments ({circ.circular_attachment.length})
                  </span>
                  <div className="flex flex-wrap gap-2">
                    {circ.circular_attachment.map((att: any) => (
                      <div
                        key={att.id}
                        className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-muted text-xs font-medium text-foreground hover:bg-muted/80 transition-colors"
                      >
                        <span>📎 {att.file_name}</span>
                        <span className="text-muted-foreground text-[10px]">
                          ({(att.size_bytes / 1024 / 1024).toFixed(2)} MB)
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

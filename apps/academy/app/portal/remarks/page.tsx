import { supabaseServer } from '@/lib/supabase/server';

export const metadata = {
  title: 'Teacher Remarks | Parent Portal',
};

export default async function PortalRemarksPage() {
  const supabase = await supabaseServer();
  const client = supabase as any;

  // Query approved remarks visible to this guardian via RLS
  const { data: remarks, error } = await client
    .from('v_guardian_student_remarks')
    .select('*')
    .order('remark_date', { ascending: false });

  const remarksList = remarks || [];

  return (
    <div className="space-y-6 w-full max-w-full">
      <div className="border-b pb-4 flex flex-col gap-1">
        <h2 className="text-xl font-bold tracking-tight text-foreground">Teacher Remarks</h2>
        <p className="text-sm text-muted-foreground">
          Official academic and behavioral remarks from class teachers approved by school administration.
        </p>
      </div>

      {remarksList.length === 0 ? (
        <div className="p-8 text-center rounded-lg border bg-card text-muted-foreground">
          <p className="text-sm font-medium">No teacher remarks have been published for your child yet.</p>
        </div>
      ) : (
        <div className="flex flex-col gap-4">
          {remarksList.map((remark: any) => {
            const isUrdu = remark.language === 'ur';
            const remarkDate = remark.remark_date
              ? new Date(remark.remark_date).toLocaleDateString('en-GB', {
                  day: 'numeric',
                  month: 'short',
                  year: 'numeric',
                })
              : '';

            return (
              <div
                key={remark.version_id}
                className="p-4 sm:p-5 rounded-lg border bg-card text-card-foreground shadow-sm space-y-3 w-full max-w-full overflow-hidden"
              >
                {/* Header with Student and Meta */}
                <div className="flex flex-wrap items-center justify-between gap-2 border-b pb-2.5">
                  <div className="flex items-center gap-2">
                    <span className="font-semibold text-sm text-foreground">
                      {remark.student_name_en}
                    </span>
                    {remark.student_name_ur && (
                      <span className="text-xs text-muted-foreground font-urdu" dir="rtl">
                        ({remark.student_name_ur})
                      </span>
                    )}
                    <span className="text-xs px-2 py-0.5 rounded bg-muted text-muted-foreground">
                      GR: {remark.gr_number}
                    </span>
                  </div>

                  <div className="flex items-center gap-2">
                    <span
                      className={`text-[11px] font-medium px-2 py-0.5 rounded ${
                        isUrdu
                          ? 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200'
                          : 'bg-blue-100 text-blue-900 dark:bg-blue-950 dark:text-blue-200'
                      }`}
                    >
                      {isUrdu ? 'Urdu / اردو' : 'English'}
                    </span>
                    <span className="text-xs text-muted-foreground">{remarkDate}</span>
                  </div>
                </div>

                {/* Remark Body text with RTL support */}
                <div
                  dir={isUrdu ? 'rtl' : 'ltr'}
                  className={`w-full max-w-full break-words text-sm sm:text-base leading-relaxed ${
                    isUrdu
                      ? 'text-right font-serif sm:text-lg text-emerald-950 dark:text-emerald-100'
                      : 'text-left text-foreground'
                  }`}
                  style={{ wordBreak: 'break-word', overflowWrap: 'anywhere' }}
                >
                  <p>{remark.body}</p>
                </div>

                {/* Footer with Author and Campus */}
                <div className="flex flex-wrap items-center justify-between text-xs text-muted-foreground pt-1 border-t border-dashed">
                  <span>Teacher: {remark.author_name || 'Class Teacher'}</span>
                  <span>{remark.campus_name}</span>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

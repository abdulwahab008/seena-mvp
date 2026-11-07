import { notFound } from 'next/navigation';
import { requireSession } from '@/lib/auth/require-session';
import { supabaseServer } from '@/lib/supabase/server';
import { Button } from '@/components/ui/button';

export const dynamic = 'force-dynamic';

export default async function PlatformLayout({ children }: { children: React.ReactNode }) {
  const user = await requireSession();
  const supabase = await supabaseServer();
  const { data: isAdmin } = await supabase.rpc('is_platform_admin');
  if (!isAdmin) notFound();

  return (
    <div className="min-h-screen bg-background">
      <header className="flex items-center justify-between border-b px-4 py-3 sm:px-6">
        <p className="font-semibold">Seena platform</p>
        <div className="flex items-center gap-3">
          <span className="hidden text-sm text-muted-foreground sm:inline">{user.email}</span>
          <form action="/api/auth/sign-out" method="post">
            <Button type="submit" variant="outline" size="sm" data-testid="sign-out">
              Sign out
            </Button>
          </form>
        </div>
      </header>
      <main className="mx-auto max-w-6xl p-4 sm:p-6">{children}</main>
    </div>
  );
}

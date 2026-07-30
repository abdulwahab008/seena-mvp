import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { AppNav } from './nav';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  return (
    <div className="mx-auto max-w-3xl p-6">
      <AppNav />
      {children}
    </div>
  );
}

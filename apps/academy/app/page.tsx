import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';

export default async function RootPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  redirect(user ? '/campuses' : '/login');
}

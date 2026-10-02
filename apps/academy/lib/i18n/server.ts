import { supabaseServer } from '@/lib/supabase/server';
import { isLang, type Lang } from './messages';

// The preference lives on the person's own row, so it follows them across
// devices and logins.
export async function getLang(): Promise<Lang> {
  const supabase = await supabaseServer();
  const { data } = await supabase.rpc('get_preferred_language');
  return isLang(data) ? data : 'en';
}

import { supabaseServer } from '@/lib/supabase/server';
import { requireSession } from '@/lib/auth/require-session';
import { RemarksDesk } from './remarks-desk';

export const metadata = {
  title: 'Teacher Remarks & Moderation | Seena Academy',
};

export default async function StaffRemarksPage() {
  const user = await requireSession();
  const supabase = await supabaseServer();
  const client = supabase as any;

  // 1. Fetch current user role from app_user
  const { data: appUser } = await client
    .from('app_user')
    .select('app_role, full_name')
    .eq('user_id', user.id)
    .maybeSingle();

  const currentUserId = user.id;
  const userRole = appUser?.app_role || 'class_teacher';

  // 2. Fetch accessible students
  const { data: studentsData } = await client
    .from('student')
    .select('id, name_en, name_ur, gr_number')
    .eq('status', 'active')
    .order('name_en', { ascending: true })
    .limit(100);

  // 3. Fetch remarks and versions directly (resilient to PostgREST relationship caching)
  const { data: remarksData } = await client
    .from('student_remark')
    .select(`
      id,
      student_id,
      author_id,
      status,
      current_version_id,
      created_at,
      student:student_id (name_en, gr_number)
    `)
    .order('created_at', { ascending: false });

  const { data: allVersions } = await client
    .from('student_remark_version')
    .select('*')
    .order('version_number', { ascending: true });

  const { data: authors } = await client
    .from('app_user')
    .select('user_id, full_name');

  const authorMap = new Map<string, string>((authors || []).map((a: any) => [a.user_id, a.full_name]));
  const studentMap = new Map<string, any>((studentsData || []).map((s: any) => [s.id, s]));
  const remarkMap = new Map<string, any>((remarksData || []).map((r: any) => [r.id, r]));

  const versionsByRemark = new Map<string, any[]>();
  for (const v of allVersions || []) {
    const list = versionsByRemark.get(v.remark_id) || [];
    list.push(v);
    versionsByRemark.set(v.remark_id, list);
  }

  const remarks = (remarksData || []).map((r: any) => ({
    id: r.id,
    student_id: r.student_id,
    student_name: r.student?.name_en || 'Unknown Student',
    student_gr: r.student?.gr_number || '',
    author_id: r.author_id,
    author_name: authorMap.get(r.author_id) || 'Staff Member',
    status: r.status,
    current_version_id: r.current_version_id,
    created_at: r.created_at,
    versions: versionsByRemark.get(r.id) || [],
  }));

  // 4. Resolve pending versions awaiting moderation
  const pendingVersions = (allVersions || [])
    .filter((v: any) => v.status === 'pending')
    .map((p: any) => {
      const remark = remarkMap.get(p.remark_id);
      const student = remark ? studentMap.get(remark.student_id) : null;
      return {
        version_id: p.id,
        remark_id: p.remark_id,
        student_name: student?.name_en || remark?.student?.name_en || 'Student',
        student_gr: student?.gr_number || remark?.student?.gr_number || '',
        author_name: remark ? authorMap.get(remark.author_id) || 'Teacher' : 'Teacher',
        version_number: p.version_number,
        body: p.body,
        language: p.language,
        created_at: p.created_at,
      };
    });

  // 5. Fetch campus policies
  const { data: campusesData } = await client
    .from('campus')
    .select('id, name')
    .order('name');

  const { data: policiesData } = await client
    .from('campus_portal_policy')
    .select('*');

  const policyMap = new Map((policiesData || []).map((p: any) => [p.campus_id, p.require_remark_approval]));

  const policies = (campusesData || []).map((c: any) => ({
    campus_id: c.id,
    campus_name: c.name,
    require_remark_approval: policyMap.has(c.id) ? policyMap.get(c.id) : true,
  }));

  return (
    <div className="p-6 space-y-6 max-w-6xl mx-auto">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Student Remarks & Moderation</h1>
        <p className="text-sm text-muted-foreground">
          Author, moderate, and manage official guardian notes with immutable PECA-compliant versioning.
        </p>
      </div>

      <RemarksDesk
        students={studentsData || []}
        remarks={remarks}
        pendingVersions={pendingVersions}
        policies={policies}
        currentUserId={currentUserId}
        userRole={userRole}
      />
    </div>
  );
}

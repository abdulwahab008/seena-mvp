-- RLS helpers evaluated once per query instead of once per row.
-- my_student_id() and auth_guardian_student_ids() are SECURITY DEFINER with a pinned search_path, so the planner cannot
-- inline them and ran a lookup for every row a policy checked; the claim readers re-parsed the JWT per row. Wrapping each
-- call in a scalar subquery turns it into an InitPlan. Same value, same semantics: the helpers take no arguments.
do $$
declare
  r   record;
  pat constant text := '(?<!select )(?<![[:alnum:]_.])((?:app\.|public\.)?(?:my_student_id|auth_guardian_student_ids|auth_tenant_id|auth_role|auth_campus_ids)\(\)|auth\.uid\(\))';
  arr constant text := 'ANY \(((?:app\.|public\.)?(?:auth_guardian_student_ids|auth_campus_ids)\(\))\)';
  q   text;
  w   text;
  sql text;
begin
  for r in
    select n.nspname, c.relname, pol.polname,
           pg_get_expr(pol.polqual, pol.polrelid) as qual, pg_get_expr(pol.polwithcheck, pol.polrelid) as chk
      from pg_policy pol join pg_class c on c.oid = pol.polrelid join pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('public', 'app')
  loop
    q := regexp_replace(regexp_replace(r.qual, arr, 'ANY ((select \1)::uuid[])', 'gi'), pat, '(select \1)', 'gi');
    w := regexp_replace(regexp_replace(r.chk,  arr, 'ANY ((select \1)::uuid[])', 'gi'), pat, '(select \1)', 'gi');
    if q is distinct from r.qual or w is distinct from r.chk then
      sql := format('alter policy %I on %I.%I', r.polname, r.nspname, r.relname);
      if r.qual is not null then sql := sql || format(' using (%s)', q); end if;
      if r.chk  is not null then sql := sql || format(' with check (%s)', w); end if;
      execute sql;
    end if;
  end loop;
end;
$$;

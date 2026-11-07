-- platform_admin joins the portal boundary (20260806000800_portal_roles_boundary.sql):
-- parent and student tokens never read it.
select app.fn_block_portal_roles('public.platform_admin');

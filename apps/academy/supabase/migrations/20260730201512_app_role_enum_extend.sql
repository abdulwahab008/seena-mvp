-- Split into its own migration for the same reason as the FR-C12 status
-- enum extension: ALTER TYPE ... ADD VALUE cannot be used in the same
-- transaction that later references the new value.
alter type public.app_role add value if not exists 'nurse';

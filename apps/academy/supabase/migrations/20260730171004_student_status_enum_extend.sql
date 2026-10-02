-- Split into its own migration: ALTER TYPE ... ADD VALUE cannot be used in
-- the same transaction that later references the new value, and each
-- migration file is its own transaction — the FR-C12 migration that
-- actually uses these values follows as a separate file.
alter type public.student_status add value if not exists 'transferred';
alter type public.student_status add value if not exists 'struck_off';
alter type public.student_status add value if not exists 'on_leave';

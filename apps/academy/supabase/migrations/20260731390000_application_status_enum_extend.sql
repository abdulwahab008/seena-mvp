-- Split into its own migration: ALTER TYPE ... ADD VALUE cannot run in the
-- same transaction that later references the new value (same reason as
-- student_status_enum_extend.sql / app_role_enum_extend.sql /
-- concession_award_status_enum_extend.sql / enquiry_status_enum_extend.sql).
alter type public.application_status add value 'test_absent';

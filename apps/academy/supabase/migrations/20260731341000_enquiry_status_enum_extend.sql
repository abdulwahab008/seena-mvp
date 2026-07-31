-- Split into its own migration, matching this codebase's established
-- convention (student_status_enum_extend.sql, app_role_enum_extend.sql,
-- concession_award_status_enum_extend.sql): ALTER TYPE ... ADD VALUE
-- cannot be used in the same transaction that later references the new
-- value, and each migration file is its own transaction — the FR-B03
-- migration that actually uses 'merged' follows as a separate file.
alter type public.enquiry_status add value if not exists 'merged';

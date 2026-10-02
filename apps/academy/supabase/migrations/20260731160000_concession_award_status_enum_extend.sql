-- Split into its own migration: ALTER TYPE ... ADD VALUE cannot be used in
-- the same transaction that later references the new value, and each
-- migration file is its own transaction — the FR-K08 migration that
-- actually uses 'expired' follows as a separate file.
alter type public.concession_award_status add value if not exists 'expired';

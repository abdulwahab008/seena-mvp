-- FR-J15 (1/2): the 'stale' status. Enum values must be committed before any
-- statement uses them, so this lives in its own migration ahead of the one
-- that adds the cascade and the policies.
alter type public.report_card_status add value if not exists 'stale';

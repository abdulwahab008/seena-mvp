-- The export worker claims the oldest queued job by created_at. With the column
-- defaulting to now() (the transaction start), two jobs requested in one
-- transaction tie and the winner depended on heap layout, which changed once
-- autovacuum reused free space. clock_timestamp() makes the queue true FIFO.

alter table public.report_export_job alter column created_at set default clock_timestamp();

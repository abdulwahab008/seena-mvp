-- Audit BUG-05: "today" was computed in UTC. Between 00:00 and 05:00 PKT every current_date,
-- now()::date and timestamptz::date in the database was still yesterday, so a voucher dated
-- today was "in the future" and default dates were a day behind. Schools run on Pakistan time;
-- make that the database's session time zone. Timestamps are stored as timestamptz and are
-- unaffected; only the calendar date derived from them changes.
alter database postgres set timezone to 'Asia/Karachi';

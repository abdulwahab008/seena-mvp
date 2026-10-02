-- FR-G03: attendance_day rows written from period attendance carry their own
-- source, so a manual daily mark can always be told apart from a derived one.
-- Alone in its migration: a new enum value cannot be used in the transaction
-- that adds it.

alter type public.student_attendance_source add value if not exists 'derived';

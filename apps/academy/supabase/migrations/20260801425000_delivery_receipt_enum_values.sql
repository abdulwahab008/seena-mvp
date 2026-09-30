-- Enum values must be committed before any statement uses them, and each
-- migration runs in one transaction — so they live in their own file ahead of
-- 20260801430000_delivery_receipt_ingestion.sql (FR-M09).
alter type public.attempt_status add value if not exists 'submitted';
alter type public.attempt_status add value if not exists 'expired';

alter type public.message_status add value if not exists 'submitted';
alter type public.message_status add value if not exists 'expired';
alter type public.message_status add value if not exists 'sent';

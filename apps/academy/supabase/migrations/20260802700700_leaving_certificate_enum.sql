-- FR-T07: School Leaving Certificate is its own certificate_type, with its own
-- serial series and printed wording, not a flavour of the Transfer Certificate.
-- A new enum value cannot be used in the transaction that adds it, so the type
-- lives in this file and everything that uses it in the next migration.
alter type public.certificate_type add value if not exists 'leaving';

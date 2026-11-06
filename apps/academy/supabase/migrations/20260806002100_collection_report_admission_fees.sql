-- Audit BUG-12: the daily collection report missed admission-fee payments, so cash taken at the
-- walk-in desk or on an application never appeared in it. Their ledger credits are added here,
-- with the payment's own mode, alongside the other sources.
create or replace view public.v_daily_collection with (security_invoker = true) as
SELECT fl.id AS ledger_id,
    fl.tenant_id,
    fl.campus_id,
    fl.value_date,
    fl.enrolment_id,
    fl.amount_paisa,
    fp.mode,
    fp.id AS payment_id,
    'fee_payment'::text AS source
   FROM fee_ledger fl
     JOIN fee_payment fp ON fp.id = fl.source_id AND fl.source_type = 'fee_payment'::text
  WHERE fl.entry_type = 'payment'::fee_ledger_entry_type
UNION ALL
 SELECT NULL::uuid AS ledger_id,
    c.tenant_id,
    c.campus_id,
    c.book_date AS value_date,
    NULL::uuid AS enrolment_id,
    c.amount_paisa,
    'cash'::fee_payment_mode AS mode,
    NULL::uuid AS payment_id,
    'inv_sale'::text AS source
   FROM v_inv_cash_book_entry c
  WHERE c.doc_type = 'sale'::inv_sale_doc_type
UNION ALL
 SELECT NULL::uuid AS ledger_id,
    f.tenant_id,
    f.campus_id,
    f.book_date AS value_date,
    NULL::uuid AS enrolment_id,
    f.amount_paisa,
    'cash'::fee_payment_mode AS mode,
    NULL::uuid AS payment_id,
    'library_fine'::text AS source
   FROM v_library_fine_cash_entry f
UNION ALL
 SELECT fl.id AS ledger_id,
    fl.tenant_id,
    fl.campus_id,
    fl.value_date,
    fl.enrolment_id,
    fl.amount_paisa,
    afp.mode,
    afp.id AS payment_id,
    'admission_fee_payment'::text AS source
   FROM fee_ledger fl
     JOIN admission_fee_payment afp ON afp.id = fl.source_id AND fl.source_type = 'admission_fee_payment'::text
  WHERE fl.entry_type = 'payment'::fee_ledger_entry_type;

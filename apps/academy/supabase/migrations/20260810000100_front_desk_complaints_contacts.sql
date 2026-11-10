-- The front desk also keeps a complaint desk and a people directory (suppliers,
-- vendors, useful numbers), on the same register as visitors and calls.
alter type public.front_desk_kind add value if not exists 'complaint';
alter type public.front_desk_kind add value if not exists 'contact';

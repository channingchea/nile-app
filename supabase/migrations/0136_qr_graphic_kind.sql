-- QR code graphics (graphics library expansions, phase 3). The enum value is
-- its own migration: a new enum value can't be used in the transaction that
-- adds it, and 0136a's payload check uses it.
alter type public.studio_graphic_kind add value if not exists 'qr';

-- P3 follow-up: tips still cascade-deleted on account deletion.
--
-- Same class of bug as #32's tickets: tips_tipper_id_fkey was ON DELETE
-- CASCADE, so a tipper erasing themselves erased the HOST's earnings record
-- along with it. Mirror the tickets fix exactly — nullable + SET NULL, plus a
-- stamp that distinguishes "anonymized tipper" from "corrupt row".
--
-- host_id is deliberately left ON DELETE CASCADE: delete-account explicitly
-- deletes the host's events first, which already cascades their tips via
-- tips_event_id_fkey, so changing it would be dead code.

alter table public.tips
  add column if not exists tipper_deleted_at timestamptz;

comment on column public.tips.tipper_deleted_at is
  'Set by delete-account when the tipper erases their account. tipper_id goes NULL at the same moment; this stamp proves the NULL is intentional.';

alter table public.tips alter column tipper_id drop not null;

alter table public.tips drop constraint tips_tipper_id_fkey;
alter table public.tips add constraint tips_tipper_id_fkey
  foreign key (tipper_id) references public.profiles(id) on delete set null;

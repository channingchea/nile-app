-- 0148: the guest share-link code moves off `events`.
--
-- 0147 put it in events.guest_invite_code, but events rows are readable by
-- every signed-in user (events_select_visible), so anyone could read any
-- show's code and add themselves to its guest list. event_guest_links has RLS
-- on, no policies and no grants: only the livekit function (service role)
-- reads or writes it. The old column is emptied and held empty by a check;
-- dropping it is left for a later migration (DROP needs a confirm).

create table public.event_guest_links (
  event_id   uuid primary key references public.events(id) on delete cascade,
  code       text not null unique check (code ~ '^[a-z2-9]{10}$'),
  created_at timestamptz not null default now()
);
alter table public.event_guest_links enable row level security;
revoke all on public.event_guest_links from anon, authenticated;

insert into public.event_guest_links (event_id, code)
  select id, guest_invite_code from public.events where guest_invite_code is not null;
update public.events set guest_invite_code = null where guest_invite_code is not null;
alter table public.events add constraint events_guest_invite_code_retired check (guest_invite_code is null);

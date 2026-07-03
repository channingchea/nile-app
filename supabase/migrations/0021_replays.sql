-- ── Replays / VOD ───────────────────────────────────────────────────────────
-- Roadmap #2. After a live show ends, LiveKit Room Composite Egress renders a
-- single composited recording (director's-cut mix) into the 'replays' storage
-- bucket. This table tracks one replay per egress run for an event.
--
-- Lifecycle: 'recording' (egress started in start-show)
--          → 'processing' (egress_ended webhook fired, file finalizing)
--          → 'ready' (playback_path written, viewable)
--          → 'failed' (egress aborted/errored).
--
-- playback_path is the object path inside the 'replays' bucket (NOT a public
-- URL). The livekit fn mints a short-lived signed URL on demand after the same
-- paid-ticket gate viewer-token uses, so paid shows stay paid on replay.

create table if not exists public.replays (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  egress_id     text unique,                       -- LiveKit egress id (webhook key)
  status        text not null default 'recording'
                  check (status in ('recording','processing','ready','failed')),
  playback_path text,                              -- object path in 'replays' bucket
  duration_ms   bigint,
  started_at    timestamptz,                       -- show start (egress start)
  created_at    timestamptz not null default now()
);

create index if not exists replays_event_id_idx on public.replays(event_id);
-- Supports the stuck-row reconcile sweep in 0024 (scan recording rows by age).
create index if not exists replays_status_created_idx on public.replays(status, created_at);

alter table public.replays enable row level security;

-- Read gate mirrors viewer-token: host, assigned operator, or paid-ticket holder
-- for paid events; anyone for free events. (Clients only ever see 'ready' rows
-- because non-ready rows have no playback; the signed-URL action re-checks too.)
drop policy if exists "replays_select_authorized" on public.replays;
create policy "replays_select_authorized" on public.replays
  for select using (
    exists (
      select 1 from public.events e
      where e.id = replays.event_id
        and (
          e.host_id = auth.uid()
          or coalesce(e.price, 0) = 0
          or exists (
            select 1 from public.event_operators o
            where o.event_id = e.id and o.operator_id = auth.uid()
          )
          or exists (
            select 1 from public.tickets t
            where t.event_id = e.id
              and t.buyer_id = auth.uid()
              and t.status = 'paid'
          )
        )
    )
  );

-- Writes are server-side only (livekit fn + webhook use the service role, which
-- bypasses RLS). No insert/update/delete policy for clients.

-- Storage bucket for composited replay files. PRIVATE — playback is via signed
-- URLs minted server-side, unlike the public 'posts'/'messages' buckets.
insert into storage.buckets (id, name, public)
values ('replays', 'replays', false)
on conflict (id) do nothing;

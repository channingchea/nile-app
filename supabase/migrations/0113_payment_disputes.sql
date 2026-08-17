-- 0113 — P2 #18 from the 2026-08-16 platform review: chargebacks and disputes.
--
-- The webhook handled exactly two Stripe events: checkout.session.completed and
-- charge.refunded. A dispute was invisible. Concretely, on a disputed $2,500
-- sponsorship Stripe pulls the funds plus a $15 fee, and Nile keeps serving the
-- ad, keeps the advertiser trusted, and keeps the host's destination transfer.
-- On a disputed ticket the buyer keeps live + replay access and the host is
-- still paid, on money that has already left the platform balance.
--
-- Shape: 'disputed' is a real status on the three things money buys, so the
-- gates that already read those statuses revoke access with no new checks
-- anywhere — the door (livekit), chat (live-chat), the replay gate, and
-- host_ticket_earnings all test = 'paid' and stop matching the moment a row
-- flips. payment_disputes is the ledger beside it: what was disputed, what it
-- cost, what we already paid out on it, and how it ended.

-- ── 'disputed' as a first-class status ──────────────────────────────────────
alter table public.tickets drop constraint if exists tickets_status_check;
alter table public.tickets add constraint tickets_status_check
  check (status in ('pending', 'paid', 'refunded', 'disputed'));

alter table public.tips drop constraint if exists tips_status_check;
alter table public.tips add constraint tips_status_check
  check (status in ('pending', 'paid', 'refunded', 'disputed'));

alter table public.ticket_checkouts drop constraint if exists ticket_checkouts_status_check;
alter table public.ticket_checkouts add constraint ticket_checkouts_status_check
  check (status in ('pending', 'paid', 'refunded', 'abandoned', 'oversold', 'disputed'));

-- A campaign has no 'disputed' status because it needs to stay in the state
-- machine review-ad-campaign understands. It gets paused and stamped instead,
-- and the stamp is what stops an admin resuming it by reflex.
alter table public.ad_campaigns
  add column if not exists disputed_at timestamptz;

-- ── the ledger ──────────────────────────────────────────────────────────────
create table if not exists public.payment_disputes (
  id                 uuid primary key default gen_random_uuid(),
  stripe_dispute_id  text not null unique,
  stripe_charge_id   text,
  payment_intent_id  text,
  kind               text not null
                       check (kind in ('ticket', 'tip', 'ad_campaign', 'unknown')),
  subject_id         uuid,        -- tickets.id / tips.id / ad_campaigns.id
  event_id           uuid references public.events(id) on delete set null,
  host_id            uuid references public.profiles(id) on delete set null,
  payer_id           uuid references public.profiles(id) on delete set null,
  amount_cents       integer,
  -- What the host was already paid out of this charge. On a destination charge
  -- the dispute is debited from the PLATFORM balance, so this is money Nile is
  -- out until it is recovered from the host or written off.
  exposure_cents     integer not null default 0,
  reason             text,
  status             text not null,           -- raw Stripe dispute.status
  outcome            text check (outcome in ('won', 'lost')),
  revoked            boolean not null default false,
  prior_trust_tier   text,
  opened_at          timestamptz not null default now(),
  closed_at          timestamptz,
  note               text
);

create index if not exists payment_disputes_open_idx
  on public.payment_disputes (opened_at desc) where closed_at is null;
create index if not exists payment_disputes_pi_idx
  on public.payment_disputes (payment_intent_id);

alter table public.payment_disputes enable row level security;

-- Admin-only reads. Every write is service-role, through the RPCs below, so
-- there is no insert/update/delete policy.
drop policy if exists payment_disputes_admin_select on public.payment_disputes;
create policy payment_disputes_admin_select on public.payment_disputes
  for select using (public.is_admin());

grant select on public.payment_disputes to authenticated;

-- ── open ────────────────────────────────────────────────────────────────────
-- Resolve the charge to whatever it bought, revoke it, and record the exposure.
-- Returns a jsonb summary so the webhook can act on the parts that live outside
-- Postgres: eject a viewer whose show is running, and alert an admin.
--
-- Idempotent on stripe_dispute_id: charge.dispute.created can be redelivered,
-- and 0112's dedupe only covers identical event ids.
create or replace function public.open_payment_dispute(
  p_dispute_id     text,
  p_charge_id      text,
  p_payment_intent text,
  p_amount_cents   integer,
  p_reason         text,
  p_status         text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_kind      text := 'unknown';
  v_subject   uuid;
  v_event     uuid;
  v_host      uuid;
  v_payer     uuid;
  v_exposure  integer := 0;
  v_revoked   boolean := false;
  v_prior     text;
  v_room      text;
  v_live      boolean := false;
  v_existing  public.payment_disputes%rowtype;
  v_advertiser uuid;
begin
  select * into v_existing from payment_disputes
   where stripe_dispute_id = p_dispute_id;
  if found then
    return jsonb_build_object('kind', v_existing.kind, 'duplicate', true);
  end if;

  -- ── ticket ────────────────────────────────────────────────────────────────
  select t.id, t.event_id, t.buyer_id, e.host_id, e.livekit_room,
         e.status in ('live', 'soundcheck'),
         case when t.status = 'paid'
              then t.amount_cents - coalesce(t.application_fee_cents, 0) else 0 end
    into v_subject, v_event, v_payer, v_host, v_room, v_live, v_exposure
    from tickets t
    join events e on e.id = t.event_id
   where t.stripe_payment_intent_id = p_payment_intent
   limit 1;

  if found then
    v_kind := 'ticket';
    update tickets set status = 'disputed'
     where id = v_subject and status = 'paid';
    v_revoked := found;
    update ticket_checkouts
       set status = 'disputed', settled_at = now(),
           note = concat_ws(' ', note, '— chargeback ' || p_dispute_id)
     where payment_intent_id = p_payment_intent and status = 'paid';
  else
    -- ── tip ─────────────────────────────────────────────────────────────────
    select tp.id, tp.event_id, tp.tipper_id, tp.host_id,
           case when tp.status = 'paid'
                then tp.amount_cents - coalesce(tp.fee_cents, 0) else 0 end
      into v_subject, v_event, v_payer, v_host, v_exposure
      from tips tp
     where tp.stripe_payment_intent_id = p_payment_intent
     limit 1;

    if found then
      v_kind := 'tip';
      update tips set status = 'disputed'
       where id = v_subject and status = 'paid';
      v_revoked := found;
    else
      -- ── ad campaign / sponsorship ─────────────────────────────────────────
      -- Two different columns, deliberately: advertiser_id is the PROFILE that
      -- bought a host boost, advertiser_account_id is the self-serve brand
      -- account. A campaign has one or the other, never reliably both.
      select c.id, c.event_id, e.host_id,
             coalesce(c.advertiser_id, a.profile_id), a.trust_tier,
             case when c.placement = 'lobby' and c.status in ('active', 'completed')
                  then c.budget_cents - coalesce(c.application_fee_cents, c.budget_cents)
                  else 0 end
        into v_subject, v_event, v_host, v_advertiser, v_prior, v_exposure
        from ad_campaigns c
        left join events e on e.id = c.event_id
        left join advertiser_accounts a on a.id = c.advertiser_account_id
       where c.stripe_payment_intent_id = p_payment_intent
       limit 1;

      if found then
        v_kind := 'ad_campaign';
        v_payer := v_advertiser;
        -- Stop it serving. 'completed' campaigns are already off the air and
        -- must stay terminal; pending_* rows were never captured.
        update ad_campaigns
           set status = 'paused', disputed_at = now()
         where id = v_subject and status in ('active', 'paused');
        v_revoked := found;
        -- A chargeback is the strongest possible signal that this brand should
        -- not skip the policy screen. moderate-report demotes on the same
        -- grounds; prior_trust_tier below is what makes it reversible if we
        -- win. Only demote when there is a tier to lose, so a won dispute
        -- doesn't "restore" a trust the advertiser never had.
        if v_prior = 'trusted' then
          update advertiser_accounts
             set trust_tier = 'new', trusted_at = null
           where id = (select advertiser_account_id from ad_campaigns where id = v_subject);
        end if;
      else
        v_subject := null; v_event := null; v_host := null; v_payer := null;
        v_exposure := 0;
      end if;
    end if;
  end if;

  insert into payment_disputes (
    stripe_dispute_id, stripe_charge_id, payment_intent_id, kind, subject_id,
    event_id, host_id, payer_id, amount_cents, exposure_cents, reason, status,
    revoked, prior_trust_tier
  ) values (
    p_dispute_id, p_charge_id, p_payment_intent, v_kind, v_subject,
    v_event, v_host, v_payer, p_amount_cents, greatest(v_exposure, 0), p_reason,
    p_status, v_revoked, v_prior
  )
  on conflict (stripe_dispute_id) do nothing;

  return jsonb_build_object(
    'kind', v_kind,
    'subject_id', v_subject,
    'event_id', v_event,
    'host_id', v_host,
    'payer_id', v_payer,
    'exposure_cents', greatest(v_exposure, 0),
    'revoked', v_revoked,
    'livekit_room', v_room,
    'event_live', coalesce(v_live, false),
    'duplicate', false
  );
end;
$function$;

-- ── close ───────────────────────────────────────────────────────────────────
-- Stripe closed the dispute. Won means the charge was never really lost, so the
-- buyer's access comes back. Lost means the revocation stands and the exposure
-- is real money to recover from the host.
--
-- A won campaign is NOT auto-resumed: by the time a dispute closes (weeks) the
-- flight window has usually passed, and silently restarting an ad the
-- advertiser has disowned is worse than making an admin press resume. The stamp
-- is cleared and the trust tier restored, so resume is a one-click decision.
create or replace function public.close_payment_dispute(
  p_dispute_id text,
  p_status     text,
  p_outcome    text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  d public.payment_disputes%rowtype;
begin
  select * into d from payment_disputes where stripe_dispute_id = p_dispute_id;
  if not found then
    return jsonb_build_object('kind', 'unknown', 'found', false);
  end if;

  update payment_disputes
     set status = p_status,
         outcome = case when p_outcome in ('won', 'lost') then p_outcome else outcome end,
         closed_at = now()
   where id = d.id;

  if p_outcome = 'won' and d.revoked then
    if d.kind = 'ticket' then
      update tickets set status = 'paid'
       where id = d.subject_id and status = 'disputed';
      update ticket_checkouts set status = 'paid'
       where payment_intent_id = d.payment_intent_id and status = 'disputed';
    elsif d.kind = 'tip' then
      update tips set status = 'paid'
       where id = d.subject_id and status = 'disputed';
    elsif d.kind = 'ad_campaign' then
      update ad_campaigns set disputed_at = null where id = d.subject_id;
      if d.prior_trust_tier = 'trusted' then
        update advertiser_accounts
           set trust_tier = 'trusted', trusted_at = now()
         where id = (select advertiser_account_id from ad_campaigns where id = d.subject_id)
           and trust_tier = 'new';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'kind', d.kind,
    'found', true,
    'restored', p_outcome = 'won' and d.revoked,
    'exposure_cents', d.exposure_cents,
    'host_id', d.host_id
  );
end;
$function$;

-- See 0112: revoking from anon/authenticated alone leaves the PUBLIC grant.
revoke execute on function public.open_payment_dispute(text, text, text, integer, text, text)
  from public, anon, authenticated;
revoke execute on function public.close_payment_dispute(text, text, text)
  from public, anon, authenticated;

-- Invite codes belong to anonymous Supabase Auth identities. Only the two RPCs may
-- mutate invitations; clients cannot grant access or read another installation's records.
create table public.invite_campaigns (
    id text primary key,
    active boolean not null default false,
    ends_at timestamptz,
    created_at timestamptz not null default now()
);

create table public.invite_codes (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null references auth.users(id) on delete cascade,
    campaign_id text not null references public.invite_campaigns(id),
    code text not null unique check (code ~ '^[0-9A-F]{16}$'),
    revoked_at timestamptz,
    max_redemptions integer check (max_redemptions > 0),
    created_at timestamptz not null default now(),
    unique (owner_id, campaign_id)
);

create table public.invite_redemptions (
    recipient_id uuid primary key references auth.users(id) on delete cascade,
    invite_id uuid references public.invite_codes(id) on delete set null,
    campaign_id text not null references public.invite_campaigns(id),
    entitlement text not null default 'sentient_lifetime' check (entitlement = 'sentient_lifetime'),
    redeemed_at timestamptz not null default now()
);
create index invite_redemptions_invite_id_idx on public.invite_redemptions(invite_id);

create table public.invite_redemption_attempts (
    user_id uuid primary key references auth.users(id) on delete cascade,
    window_start timestamptz not null default now(),
    attempts integer not null default 0
);

alter table public.invite_campaigns enable row level security;
alter table public.invite_codes enable row level security;
alter table public.invite_redemptions enable row level security;
alter table public.invite_redemption_attempts enable row level security;
revoke all on public.invite_campaigns, public.invite_codes,
    public.invite_redemptions, public.invite_redemption_attempts from anon, authenticated;
grant select on public.invite_codes, public.invite_redemptions to authenticated;
create policy invite_codes_owner_read on public.invite_codes for select to authenticated
    using (owner_id = (select auth.uid()));
create policy invite_redemptions_recipient_read on public.invite_redemptions for select to authenticated
    using (recipient_id = (select auth.uid()));

-- No invented deadline: administrators may set ends_at or close the campaign. Neither
-- operation touches a grant already recorded in invite_redemptions.
insert into public.invite_campaigns(id, active) values ('launch-lifetime', true);

create function public.invite_status()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    caller uuid := auth.uid();
    campaign public.invite_campaigns%rowtype;
    invitation public.invite_codes%rowtype;
    granted_at timestamptz;
    is_active boolean;
begin
    if caller is null then raise insufficient_privilege; end if;
    select * into campaign from public.invite_campaigns where id = 'launch-lifetime';
    is_active := coalesce(campaign.active and (campaign.ends_at is null or campaign.ends_at > now()), false);
    if is_active and not exists (select 1 from public.invite_codes where owner_id = caller and campaign_id = campaign.id) then
        insert into public.invite_codes(owner_id, campaign_id, code)
        values (caller, campaign.id, upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)))
        on conflict (owner_id, campaign_id) do nothing;
    end if;
    select * into invitation from public.invite_codes
        where owner_id = caller and campaign_id = 'launch-lifetime';
    select redeemed_at into granted_at from public.invite_redemptions where recipient_id = caller;
    return jsonb_build_object(
        'code', invitation.code,
        'campaignActive', is_active and invitation.revoked_at is null
            and (invitation.max_redemptions is null or invitation.max_redemptions >
                (select count(*) from public.invite_redemptions where invite_id = invitation.id)),
        'endsAt', extract(epoch from campaign.ends_at),
        'redeemedAt', extract(epoch from granted_at),
        'redemptionCount', (select count(*) from public.invite_redemptions where invite_id = invitation.id)
    );
end;
$$;

create function public.redeem_invite(p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    caller uuid := auth.uid();
    normalized text;
    invitation public.invite_codes%rowtype;
    campaign public.invite_campaigns%rowtype;
    attempt public.invite_redemption_attempts%rowtype;
begin
    if caller is null then raise insufficient_privilege; end if;
    -- One transaction per recipient, even when two different codes arrive concurrently.
    perform pg_advisory_xact_lock(hashtextextended(caller::text, 29120000));
    if exists (select 1 from public.invite_redemptions where recipient_id = caller) then
        return public.invite_status();
    end if;
    insert into public.invite_redemption_attempts(user_id) values (caller) on conflict do nothing;
    select * into attempt from public.invite_redemption_attempts where user_id = caller for update;
    if attempt.window_start <= now() - interval '1 hour' then
        update public.invite_redemption_attempts set window_start = now(), attempts = 0 where user_id = caller;
        attempt.attempts := 0;
    end if;
    if attempt.attempts >= 10 then return jsonb_build_object('error', 'rate_limited'); end if;
    -- Return failures as data so this rate-limit increment commits on invalid guesses.
    update public.invite_redemption_attempts set attempts = attempts + 1 where user_id = caller;
    if p_code is null or length(p_code) > 64 then return jsonb_build_object('error', 'invalid_code'); end if;
    normalized := upper(regexp_replace(p_code, '[-[:space:]]', '', 'g'));
    if normalized !~ '^[0-9A-F]{16}$' then return jsonb_build_object('error', 'invalid_code'); end if;
    select * into invitation from public.invite_codes where code = normalized for update;
    if not found or invitation.revoked_at is not null then return jsonb_build_object('error', 'invalid_code'); end if;
    if invitation.owner_id = caller then return jsonb_build_object('error', 'own_code'); end if;
    -- SHARE keeps a concurrent campaign closure ordered with the grant, without serializing all recipients.
    select * into campaign from public.invite_campaigns where id = invitation.campaign_id for share;
    if not campaign.active or (campaign.ends_at is not null and campaign.ends_at <= now()) then
        return jsonb_build_object('error', 'offer_ended');
    end if;
    if invitation.max_redemptions is not null and invitation.max_redemptions <=
        (select count(*) from public.invite_redemptions where invite_id = invitation.id) then
        return jsonb_build_object('error', 'code_used');
    end if;
    insert into public.invite_redemptions(recipient_id, invite_id, campaign_id)
        values (caller, invitation.id, invitation.campaign_id);
    return public.invite_status();
end;
$$;

revoke all on function public.invite_status(), public.redeem_invite(text) from public, anon;
grant execute on function public.invite_status(), public.redeem_invite(text) to authenticated;
comment on table public.invite_redemptions is
    'Permanent Sentient lifetime grants, separate from campaign eligibility and external model subscriptions.';

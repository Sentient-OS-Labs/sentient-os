-- FINAL_1000 grants the same uncapped lifetime access as WAITLIST_OGs.
-- Restore the validated, rate-limited redemption path for every app version.
create or replace function public.redeem_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    return public.redeem_invite_before_final_capacity(p_code);
end;
$$;
revoke all on function public.redeem_invite(text) from public, anon;
grant execute on function public.redeem_invite(text) to authenticated;

-- Installed apps still call this endpoint and verify the email/lateUse receipt.
-- Keep that response contract, while also granting permanent access exactly once.
create or replace function public.record_late_invite_use(p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := auth.uid();
    attempt public.invite_redemption_attempts%rowtype;
    invitation public.invite_codes%rowtype;
    campaign public.invite_campaigns%rowtype;
    address text := lower(btrim(p_email));
begin
    if caller is null then raise insufficient_privilege; end if;
    perform pg_advisory_xact_lock(hashtextextended(caller::text, 29120000));
    insert into public.invite_redemption_attempts(user_id) values (caller) on conflict do nothing;
    select * into attempt from public.invite_redemption_attempts where user_id = caller for update;
    if attempt.window_start <= now() - interval '1 hour' then
        update public.invite_redemption_attempts set window_start = now(), attempts = 0 where user_id = caller;
        attempt.attempts := 0;
    end if;
    if attempt.attempts >= 10 then return jsonb_build_object('error', 'rate_limited'); end if;
    update public.invite_redemption_attempts set attempts = attempts + 1 where user_id = caller;
    if address is null or octet_length(address) not between 3 and 254
        or address !~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
        or address ~ '[[:cntrl:]]' then
        return jsonb_build_object('error', 'email_required');
    end if;
    select * into invitation from public.invite_codes
        where public.normalize_invite_code(code) = 'FINAL_1000' for update;
    if not found or invitation.revoked_at is not null then
        return jsonb_build_object('error', 'offer_ended');
    end if;
    if invitation.owner_id = caller then return jsonb_build_object('error', 'own_code'); end if;
    select * into campaign from public.invite_campaigns where id = invitation.campaign_id for share;
    if not found or not campaign.active or (campaign.ends_at is not null and campaign.ends_at <= now()) then
        return jsonb_build_object('error', 'offer_ended');
    end if;
    insert into public.invite_redemptions(recipient_id, invite_id, campaign_id)
        values (caller, invitation.id, invitation.campaign_id)
        on conflict (recipient_id) do nothing;
    insert into public.invite_code_late_uses(user_id, email) values (caller, address)
        on conflict (user_id) do update set email = excluded.email;
    return public.invite_status() || jsonb_build_object('validatedCode', 'FINAL_1000');
end;
$$;
revoke all on function public.record_late_invite_use(text) from public, anon;
grant execute on function public.record_late_invite_use(text) to authenticated;

-- Upgrade earlier courtesy gifts, keeping any pre-existing lifetime receipt intact.
-- The history/email rows stay private and remain readable only through caller status.
insert into public.invite_redemptions(recipient_id, invite_id, campaign_id, redeemed_at)
select late.user_id, invitation.id, invitation.campaign_id, late.first_seen_at
from public.invite_code_late_uses late
join public.invite_codes invitation
    on public.normalize_invite_code(invitation.code) = late.invite_code
on conflict (recipient_id) do nothing;

comment on table public.invite_code_late_uses is
    'Legacy FINAL_1000 courtesy-gift history and supplied email. These users now also have lifetime redemptions. Not a verified email identity or expiration rule.';

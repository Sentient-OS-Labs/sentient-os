-- Register founder-issued gifts alongside automatically generated referrals.
-- Admin-issued codes need no synthetic Auth identity. Existing ownership is preserved.
alter table public.invite_codes alter column owner_id drop not null;

insert into public.invite_codes(campaign_id, code)
select 'launch-lifetime', gift.code
from (values ('WAITLIST_OGs'), ('MACAPPS_1000'), ('FINAL_1000')) as gift(code)
where not exists (
    select 1 from public.invite_codes existing
    where public.normalize_invite_code(existing.code) = public.normalize_invite_code(gift.code)
)
on conflict do nothing;

-- Keep issuance and sharing unchanged; only registered, available codes redeem.
create or replace function public.redeem_invite(p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
    caller uuid := auth.uid();
    normalized text;
    legacy_code text;
    invitation public.invite_codes%rowtype;
    campaign public.invite_campaigns%rowtype;
    attempt public.invite_redemption_attempts%rowtype;
begin
    if caller is null then raise insufficient_privilege; end if;
    -- One transaction per recipient, even when two different codes arrive concurrently.
    perform pg_advisory_xact_lock(hashtextextended(caller::text, 29120000));
    insert into public.invite_redemption_attempts(user_id) values (caller) on conflict do nothing;
    select * into attempt from public.invite_redemption_attempts where user_id = caller for update;
    if attempt.window_start <= now() - interval '1 hour' then
        update public.invite_redemption_attempts set window_start = now(), attempts = 0 where user_id = caller;
        attempt.attempts := 0;
    end if;
    if attempt.attempts >= 10 then return jsonb_build_object('error', 'rate_limited'); end if;
    -- Return failures as data so this rate-limit increment commits on invalid guesses.
    update public.invite_redemption_attempts set attempts = attempts + 1 where user_id = caller;
    normalized := public.normalize_invite_code(p_code);
    if normalized is null or normalized = '' then return jsonb_build_object('error', 'invalid_code'); end if;
    select * into invitation from public.invite_codes
        where extensions.digest(public.normalize_invite_code(code), 'sha256') = extensions.digest(normalized, 'sha256')
          and public.normalize_invite_code(code) = normalized
        for update;
    if not found then
        -- Old apps shared hex codes with hyphens and accepted separators inside
        -- generated codes. Try that spelling only after checking the custom text.
        legacy_code := regexp_replace(normalized, '[-[:space:]]', '', 'g');
        if legacy_code ~ '^([0-9A-Z]{6}|[0-9A-F]{16})$' then
            select * into invitation from public.invite_codes
                where extensions.digest(public.normalize_invite_code(code), 'sha256') = extensions.digest(legacy_code, 'sha256')
                  and code = legacy_code
                for update;
        end if;
    end if;
    if invitation.id is null or invitation.revoked_at is not null then return jsonb_build_object('error', 'invalid_code'); end if;
    if invitation.owner_id = caller then return jsonb_build_object('error', 'own_code'); end if;
    -- SHARE keeps a concurrent campaign closure ordered with the grant, without serializing all recipients.
    select * into campaign from public.invite_campaigns where id = invitation.campaign_id for share;
    if not found or not campaign.active or (campaign.ends_at is not null and campaign.ends_at <= now()) then
        return jsonb_build_object('error', 'offer_ended');
    end if;
    -- Validation also applies to recipients with saved access. A valid replay
    -- preserves their original receipt and never credits a second invitation.
    insert into public.invite_redemptions(recipient_id, invite_id, campaign_id)
        values (caller, invitation.id, invitation.campaign_id)
        on conflict (recipient_id) do nothing;
    return public.invite_status() || jsonb_build_object('validatedCode', normalized);
end;
$$;

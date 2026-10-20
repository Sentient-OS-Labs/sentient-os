-- FINAL_1000 is now a courtesy gift, not a new lifetime redemption.
-- Preserve all previous grants. Late use is recorded independently and has no expiry gate.
create table public.invite_code_late_uses (
    user_id uuid primary key references auth.users(id) on delete cascade,
    invite_code text not null default 'FINAL_1000' check (invite_code = 'FINAL_1000'),
    email text not null check (
        octet_length(email) between 3 and 254
        and email = lower(btrim(email))
        and email ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
        and email !~ '[[:cntrl:]]'
    ),
    first_seen_at timestamptz not null default now()
);
create index invite_code_late_uses_email_idx on public.invite_code_late_uses(email);
alter table public.invite_code_late_uses enable row level security;
alter table public.invite_code_late_uses force row level security;
revoke all on table public.invite_code_late_uses from public, anon, authenticated;
grant all on table public.invite_code_late_uses to service_role;
comment on table public.invite_code_late_uses is
    'Late code use and the email supplied for that gift. Not a redemption, lifetime grant, verified email identity, or expiration rule.';

-- Keep the existing issuance/status implementation and expose only the caller's late-use receipt.
alter function public.invite_status() rename to invite_status_before_late_use;
revoke all on function public.invite_status_before_late_use() from public, anon, authenticated;
create function public.invite_status()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare receipt jsonb;
begin
    if auth.uid() is null then raise insufficient_privilege; end if;
    select jsonb_build_object('code', invite_code, 'recordedAt', extract(epoch from first_seen_at), 'email', email)
        into receipt from public.invite_code_late_uses where user_id = auth.uid();
    return public.invite_status_before_late_use() || jsonb_build_object('lateUse', receipt);
end;
$$;
revoke all on function public.invite_status() from public, anon;
grant execute on function public.invite_status() to authenticated;

-- Older clients must not keep creating lifetime grants for the closed code.
-- They get their existing "offer ended" UI; newer clients use the acknowledgement RPC below.
alter function public.redeem_invite(text) rename to redeem_invite_before_final_capacity;
revoke all on function public.redeem_invite_before_final_capacity(text) from public, anon, authenticated;
create function public.redeem_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null then raise insufficient_privilege; end if;
    if public.normalize_invite_code(p_code) = 'FINAL_1000'
        and not exists (select 1 from public.invite_redemptions where recipient_id = auth.uid()) then
        return jsonb_build_object('error', 'offer_ended');
    end if;
    return public.redeem_invite_before_final_capacity(p_code);
end;
$$;
revoke all on function public.redeem_invite(text) from public, anon;
grant execute on function public.redeem_invite(text) to authenticated;

create function public.record_late_invite_use(p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    caller uuid := auth.uid();
    attempt public.invite_redemption_attempts%rowtype;
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
    if not exists (select 1 from public.invite_codes
        where public.normalize_invite_code(code) = 'FINAL_1000' and revoked_at is null) then
        return jsonb_build_object('error', 'offer_ended');
    end if;
    insert into public.invite_code_late_uses(user_id, email) values (caller, address)
        on conflict (user_id) do update set email = excluded.email;
    return public.invite_status() || jsonb_build_object('validatedCode', 'FINAL_1000');
end;
$$;
revoke all on function public.record_late_invite_use(text) from public, anon;
grant execute on function public.record_late_invite_use(text) to authenticated;

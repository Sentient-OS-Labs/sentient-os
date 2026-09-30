-- Run inside a transaction and roll it back, including every disposable Auth identity.
do $$
declare
    sender uuid := gen_random_uuid();
    friend uuid := gen_random_uuid();
    second_friend uuid := gen_random_uuid();
    third_friend uuid := gen_random_uuid();
    additional_friend uuid;
    snapshot jsonb;
    sender_code text;
    friend_code text;
    granted jsonb;
    n integer;
begin
    if exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'invite_codes' and column_name = 'max_redemptions') then
        raise exception 'Invite codes still support a redemption cap';
    end if;
    update public.invite_campaigns set active = true, ends_at = null where id = 'launch-lifetime';
    insert into auth.users(id, aud, role, is_anonymous)
    values (sender, 'authenticated', 'authenticated', true),
           (friend, 'authenticated', 'authenticated', true),
           (second_friend, 'authenticated', 'authenticated', true),
           (third_friend, 'authenticated', 'authenticated', true);

    perform set_config('request.jwt.claims', jsonb_build_object('sub', sender, 'role', 'authenticated')::text, true);
    set local role authenticated;
    snapshot := public.invite_status();
    sender_code := snapshot->>'code';
    if sender_code is null or sender_code !~ '^[0-9A-F]{16}$' or snapshot->>'redeemedAt' is not null then
        raise exception 'New installation received an invalid code or an unearned grant';
    end if;
    if public.invite_status()->>'code' is distinct from sender_code then raise exception 'Code changed on retry'; end if;
    if public.redeem_invite(sender_code)->>'error' is distinct from 'own_code' then raise exception 'Self-invite accepted'; end if;
    begin
        insert into public.invite_redemptions(recipient_id, campaign_id) values (sender, 'launch-lifetime');
        raise exception 'Client could grant itself access';
    exception when insufficient_privilege then null;
    end;
    reset role;

    perform set_config('request.jwt.claims', jsonb_build_object('sub', friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    snapshot := public.invite_status();
    friend_code := snapshot->>'code';
    select count(*) into n from public.invite_codes where owner_id = sender;
    if n <> 0 then raise exception 'Another installation code was readable'; end if;
    if public.redeem_invite('invalid')->>'error' is distinct from 'invalid_code' then raise exception 'Invalid code accepted'; end if;
    granted := public.redeem_invite('  ' || lower(substr(sender_code, 1, 8)) || '-' || lower(substr(sender_code, 9)) || '  ');
    if granted->>'redeemedAt' is null then raise exception 'Formatted code did not redeem'; end if;
    if public.redeem_invite(sender_code)->>'redeemedAt' is distinct from granted->>'redeemedAt' then raise exception 'Retry duplicated grant'; end if;
    if public.redeem_invite(friend_code)->>'redeemedAt' is distinct from granted->>'redeemedAt' then raise exception 'Already granted recipient changed'; end if;
    begin
        update public.invite_codes set revoked_at = null;
        raise exception 'Client could change invitation availability';
    exception when insufficient_privilege then null;
    end;
    reset role;

    perform set_config('request.jwt.claims', jsonb_build_object('sub', second_friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if public.redeem_invite(sender_code)->>'redeemedAt' is null then raise exception 'Reusable code rejected second friend'; end if;
    select count(*) into n from public.invite_redemptions where recipient_id = friend;
    if n <> 0 then raise exception 'Another recipient grant was readable'; end if;
    reset role;

    -- The same code stays shareable after many distinct recipients, even within one
    -- hour. Guess throttling belongs to the recipient, never to the shared code.
    for n in 1..25 loop
        additional_friend := gen_random_uuid();
        insert into auth.users(id, aud, role, is_anonymous)
        values (additional_friend, 'authenticated', 'authenticated', true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', additional_friend, 'role', 'authenticated')::text, true);
        set local role authenticated;
        snapshot := public.redeem_invite(sender_code);
        if snapshot->>'redeemedAt' is null then raise exception 'Reusable code rejected additional friend %', n; end if;
        if public.redeem_invite(sender_code)->>'redeemedAt' is distinct from snapshot->>'redeemedAt' then
            raise exception 'Retry changed additional friend grant %', n;
        end if;
        reset role;
    end loop;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', sender, 'role', 'authenticated')::text, true);
    set local role authenticated;
    snapshot := public.invite_status();
    if snapshot->>'code' is distinct from sender_code or (snapshot->>'campaignActive')::boolean is distinct from true then
        raise exception 'Shared code changed or stopped being shareable';
    end if;
    if (snapshot->>'redemptionCount')::integer is distinct from 27 then
        raise exception 'Shared code did not count exactly 27 distinct recipients';
    end if;
    reset role;

    perform set_config('request.jwt.claims', jsonb_build_object('sub', third_friend, 'role', 'authenticated')::text, true);
    update public.invite_codes set revoked_at = now() where owner_id = sender;
    set local role authenticated;
    if public.redeem_invite(sender_code)->>'error' is distinct from 'invalid_code' then raise exception 'Revoked code accepted'; end if;
    reset role;
    update public.invite_codes set revoked_at = null where owner_id = sender;

    update public.invite_campaigns set ends_at = now() - interval '1 second' where id = 'launch-lifetime';
    set local role authenticated;
    if public.redeem_invite(sender_code)->>'error' is distinct from 'offer_ended' then raise exception 'Expired offer accepted'; end if;
    reset role;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    snapshot := public.invite_status();
    if (snapshot->>'campaignActive')::boolean is distinct from false or snapshot->>'redeemedAt' is distinct from granted->>'redeemedAt' then
        raise exception 'Campaign expiry removed a grant or remained shareable';
    end if;
    reset role;
    update public.invite_campaigns set ends_at = null, active = false where id = 'launch-lifetime';
    perform set_config('request.jwt.claims', jsonb_build_object('sub', third_friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if public.redeem_invite(sender_code)->>'error' is distinct from 'offer_ended' then raise exception 'Closed campaign accepted'; end if;
    reset role;
    update public.invite_campaigns set active = true where id = 'launch-lifetime';
    delete from public.invite_redemption_attempts where user_id = third_friend;
    set local role authenticated;
    for n in 1..10 loop perform public.redeem_invite('bad'); end loop;
    if public.redeem_invite(sender_code)->>'error' is distinct from 'rate_limited' then raise exception 'Rate limit did not persist'; end if;
    reset role;

    -- Deleting an inviter must not revoke a friend's already-earned lifetime grant.
    delete from auth.users where id = sender;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if public.invite_status()->>'redeemedAt' is distinct from granted->>'redeemedAt' then raise exception 'Inviter deletion removed grant'; end if;
    reset role;

    perform set_config('request.jwt.claims', '{}', true);
    set local role anon;
    begin
        perform public.invite_status();
        raise exception 'Unauthenticated caller issued a code';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.redeem_invite(sender_code);
        raise exception 'Unauthenticated caller redeemed a code';
    exception when insufficient_privilege then null;
    end;
    reset role;
end;
$$;
select 'PASS: 27 recipients per code, stable sharing, replay, issuance, normalization, isolation, immutable grants, revocation, expiry, guess throttling, deletion, anonymous denial' as invitation_checks;

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
    if sender_code is null or sender_code !~ '^[0-9A-Z]{6}$' or snapshot->>'redeemedAt' is not null then
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
    granted := public.redeem_invite('  ' || lower(substr(sender_code, 1, 3)) || '-' || lower(substr(sender_code, 4)) || '  ');
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

-- Compatibility is exercised with isolated identities, never a real user's code.
do $$
declare
    sender uuid := gen_random_uuid();
    friend uuid := gen_random_uuid();
    legacy text := upper(replace(gen_random_uuid()::text, '-', ''));
    snapshot jsonb;
begin
    legacy := substr(legacy, 1, 16);
    insert into auth.users(id, aud, role, is_anonymous)
    values (sender, 'authenticated', 'authenticated', true),
           (friend, 'authenticated', 'authenticated', true);
    insert into public.invite_codes(owner_id, campaign_id, code)
    values (sender, 'launch-lifetime', legacy);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', sender, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if public.invite_status()->>'code' is distinct from legacy then
        raise exception 'An existing code was replaced';
    end if;
    begin
        perform public.generate_invite_code();
        raise exception 'Client called the server-only generator';
    exception when insufficient_privilege then null;
    end;
    reset role;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    snapshot := public.redeem_invite(U&'\00A0' || lower(substr(legacy, 1, 8)) || '-' || lower(substr(legacy, 9)) || U&'\00A0');
    if snapshot->>'redeemedAt' is null or snapshot->>'code' !~ '^[0-9A-Z]{6}$' then
        raise exception 'Legacy redemption or new recipient code failed';
    end if;
    reset role;
end;
$$;

-- Founder-issued text is opaque apart from case and surrounding whitespace.
do $$
declare
    sender uuid;
    friend uuid;
    duplicate_owner uuid := gen_random_uuid();
    custom_code text;
    long_code text;
    invitation_id uuid;
    snapshot jsonb;
begin
    select string_agg(md5(n::text), '' order by n) into long_code from generate_series(1, 256) n;
    insert into auth.users(id, aud, role, is_anonymous)
    values (duplicate_owner, 'authenticated', 'authenticated', true);
    foreach custom_code in array array['X', '-', 'HELLO', 'WELCOME', 'Founders2026Code!',
                                      'Founder''s Circle / 2026! 🚀', 'Café-你好 🎉',
                                      'Founders Circle', 'Founders  Circle', 'FoundersCircle', long_code] loop
        sender := gen_random_uuid();
        friend := gen_random_uuid();
        insert into auth.users(id, aud, role, is_anonymous)
        values (sender, 'authenticated', 'authenticated', true),
               (friend, 'authenticated', 'authenticated', true);
        insert into public.invite_codes(owner_id, campaign_id, code)
        values (sender, 'launch-lifetime', custom_code) returning id into invitation_id;
        begin
            insert into public.invite_codes(owner_id, campaign_id, code)
            values (duplicate_owner, 'launch-lifetime', E' \t' || lower(custom_code) || U&'\00A0');
            raise exception 'Case/edge-space variant created a duplicate code';
        exception when unique_violation then null;
        end;
        perform set_config('request.jwt.claims', jsonb_build_object('sub', sender, 'role', 'authenticated')::text, true);
        set local role authenticated;
        if public.invite_status()->>'code' is distinct from custom_code then
            raise exception 'Custom code spelling changed';
        end if;
        if public.redeem_invite(custom_code)->>'error' is distinct from 'own_code' then
            raise exception 'Custom self-invite accepted';
        end if;
        reset role;
        perform set_config('request.jwt.claims', jsonb_build_object('sub', friend, 'role', 'authenticated')::text, true);
        set local role authenticated;
        snapshot := public.redeem_invite(U&'\00A0' || lower(custom_code) || E'\n');
        if snapshot->>'redeemedAt' is null then raise exception 'Custom invite did not redeem'; end if;
        reset role;
        if (select invite_id from public.invite_redemptions where recipient_id = friend) is distinct from invitation_id then
            raise exception 'Custom invite credited the wrong code';
        end if;
    end loop;

    foreach custom_code in array array['', E' \t\n\r', U&'\00A0\200B\202F\3000'] loop
        begin
            insert into public.invite_codes(owner_id, campaign_id, code)
            values (duplicate_owner, 'launch-lifetime', custom_code);
            raise exception 'Blank code stored';
        exception when check_violation then null;
        end;
    end loop;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', duplicate_owner, 'role', 'authenticated')::text, true);
    set local role authenticated;
    foreach custom_code in array array[null, '', E' \t\n', U&'\00A0\200B\202F\3000'] loop
        if public.redeem_invite(custom_code)->>'error' is distinct from 'invalid_code' then
            raise exception 'Blank code redeemed';
        end if;
    end loop;
    begin
        insert into public.invite_codes(owner_id, campaign_id, code)
        values (duplicate_owner, 'launch-lifetime', 'Client-created code');
        raise exception 'Client could create a custom invite';
    exception when insufficient_privilege then null;
    end;
    reset role;
end;
$$;

-- An exact custom spelling wins over legacy separator handling, even if revoked.
do $$
declare
    legacy_owner uuid := gen_random_uuid();
    custom_owner uuid := gen_random_uuid();
    friend uuid := gen_random_uuid();
    another_friend uuid := gen_random_uuid();
    legacy text;
    custom_code text;
    custom_id uuid;
begin
    select upper(lpad(to_hex(n), 6, '0')) into legacy from generate_series(0, 10000) n
        where not exists (select 1 from public.invite_codes where code = upper(lpad(to_hex(n), 6, '0'))) limit 1;
    custom_code := substr(legacy, 1, 3) || '-' || substr(legacy, 4);
    insert into auth.users(id, aud, role, is_anonymous)
    values (legacy_owner, 'authenticated', 'authenticated', true),
           (custom_owner, 'authenticated', 'authenticated', true),
           (friend, 'authenticated', 'authenticated', true),
           (another_friend, 'authenticated', 'authenticated', true);
    insert into public.invite_codes(owner_id, campaign_id, code) values (legacy_owner, 'launch-lifetime', legacy);
    insert into public.invite_codes(owner_id, campaign_id, code)
    values (custom_owner, 'launch-lifetime', custom_code) returning id into custom_id;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if public.redeem_invite(lower(custom_code))->>'redeemedAt' is null then raise exception 'Exact custom spelling rejected'; end if;
    reset role;
    if (select invite_id from public.invite_redemptions where recipient_id = friend) is distinct from custom_id then
        raise exception 'Legacy fallback overrode exact custom spelling';
    end if;
    update public.invite_codes set revoked_at = now() where id = custom_id;
    perform set_config('request.jwt.claims', jsonb_build_object('sub', another_friend, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if public.redeem_invite(custom_code)->>'error' is distinct from 'invalid_code' then
        raise exception 'Revoked custom code fell back to another invite';
    end if;
    reset role;
end;
$$;

-- Force a collision without depending on a random draw. Restore the real
-- generator at the savepoint; the enclosing test transaction rolls back all rows.
savepoint invite_collision_check;
create temporary sequence invite_collision_attempts;
create or replace function public.generate_invite_code()
returns text
language plpgsql volatile set search_path = ''
as $$
begin
    if nextval('pg_temp.invite_collision_attempts') = 1 then
        return current_setting('sentient.test_existing_code');
    end if;
    return current_setting('sentient.test_next_code');
end;
$$;
do $$
declare
    existing_owner uuid := gen_random_uuid();
    new_owner uuid := gen_random_uuid();
    exhausted_owner uuid := gen_random_uuid();
    existing_code text;
    next_code text;
    snapshot jsonb;
begin
    -- Pick two genuinely unused fixture values independently of the stubbed generator.
    select upper(lpad(to_hex(n), 6, '0')) into existing_code from generate_series(0, 10000) n
        where not exists (select 1 from public.invite_codes where code = upper(lpad(to_hex(n), 6, '0'))) limit 1;
    select upper(lpad(to_hex(n), 6, '0')) into next_code from generate_series(0, 10000) n
        where upper(lpad(to_hex(n), 6, '0')) <> existing_code
        and not exists (select 1 from public.invite_codes where code = upper(lpad(to_hex(n), 6, '0'))) limit 1;
    perform set_config('sentient.test_existing_code', existing_code, true);
    perform set_config('sentient.test_next_code', next_code, true);
    insert into auth.users(id, aud, role, is_anonymous)
    values (existing_owner, 'authenticated', 'authenticated', true),
           (new_owner, 'authenticated', 'authenticated', true),
           (exhausted_owner, 'authenticated', 'authenticated', true);
    insert into public.invite_codes(owner_id, campaign_id, code)
    values (existing_owner, 'launch-lifetime', existing_code);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', new_owner, 'role', 'authenticated')::text, true);
    set local role authenticated;
    snapshot := public.invite_status();
    if snapshot->>'code' is distinct from next_code then raise exception 'Collision was not retried'; end if;
    if public.invite_status()->>'code' is distinct from next_code then raise exception 'Retry changed the issued code'; end if;
    reset role;
    if currval('pg_temp.invite_collision_attempts') <> 2 then raise exception 'Unexpected collision retry count'; end if;
    if (select code from public.invite_codes where owner_id = existing_owner) is distinct from existing_code then
        raise exception 'Collision changed another owner code';
    end if;
    perform set_config('sentient.test_next_code', existing_code, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', exhausted_owner, 'role', 'authenticated')::text, true);
    set local role authenticated;
    begin
        perform public.invite_status();
        raise exception 'Repeated collisions should fail within the retry bound';
    exception when unique_violation then null;
    end;
    reset role;
    if currval('pg_temp.invite_collision_attempts') <> 34 then raise exception 'Collision retry limit was not 32'; end if;
    if exists (select 1 from public.invite_codes where owner_id = exhausted_owner) then
        raise exception 'Failed allocation left an invite behind';
    end if;
end;
$$;
rollback to savepoint invite_collision_check;
release savepoint invite_collision_check;
select 'PASS: 27 recipients per code, stable sharing, replay, issuance, normalization, isolation, immutable grants, revocation, expiry, guess throttling, deletion, anonymous denial' as invitation_checks;
select 'PASS: six-character issuance, legacy compatibility, private generator, collision retry and bounded exhaustion' as invitation_format_checks;
select 'PASS: arbitrary custom text, long codes, preserved spelling, normalized uniqueness, blank denial, client creation denial, exact-match precedence' as custom_invitation_checks;

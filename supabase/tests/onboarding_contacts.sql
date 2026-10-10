-- Run in a transaction and roll back. All addresses and identities are synthetic.
do $$
declare
    first_user uuid := gen_random_uuid();
    second_user uuid := gen_random_uuid();
    fields text[];
    invalid jsonb;
    oversized jsonb;
begin
    select array_agg(column_name::text order by ordinal_position) into fields
    from information_schema.columns
    where table_schema = 'public' and table_name = 'onboarding_contact_emails';
    if fields is distinct from array['email'] then raise exception 'Onboarding contains non-email fields'; end if;
    if not exists (select 1 from pg_class where oid = 'public.onboarding_contact_emails'::regclass
                   and relrowsecurity and relforcerowsecurity) then
        raise exception 'Onboarding list must force RLS';
    end if;

    insert into auth.users(id, aud, role, is_anonymous)
    values (first_user, 'authenticated', 'authenticated', true),
           (second_user, 'authenticated', 'authenticated', true);

    perform set_config('request.jwt.claims', jsonb_build_object('sub', first_user)::text, true);
    set local role authenticated;
    perform public.add_onboarding_emails('["onboarding-first@example.invalid", "onboarding-first@example.invalid"]');
    perform public.add_onboarding_emails('["onboarding-second@example.invalid"]');
    begin
        perform email from public.onboarding_contact_emails;
        raise exception 'Client can read onboarding contacts';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into public.onboarding_contact_emails values ('direct@example.invalid');
        raise exception 'Client can bypass the onboarding RPC';
    exception when insufficient_privilege then null;
    end;
    begin
        update public.onboarding_contact_emails set email = 'changed@example.invalid';
        raise exception 'Client can update onboarding contacts';
    exception when insufficient_privilege then null;
    end;
    begin
        delete from public.onboarding_contact_emails;
        raise exception 'Client can delete onboarding contacts';
    exception when insufficient_privilege then null;
    end;

    foreach invalid in array array[
        null::jsonb, 'null'::jsonb, '{}'::jsonb, '[]'::jsonb,
        '[{"email":"nested@example.invalid"}]'::jsonb,
        '[123]'::jsonb, '[null]'::jsonb, '[true]'::jsonb,
        '["Case@example.invalid"]'::jsonb, '[" spaced@example.invalid"]'::jsonb,
        '["onboarding-atomic@example.invalid","invalid"]'::jsonb,
        '["line\nbreak@example.invalid"]'::jsonb,
        jsonb_build_array(repeat('a', 255) || '@example.invalid')
    ] loop
        begin
            perform public.add_onboarding_emails(invalid);
            raise exception 'Invalid onboarding payload accepted';
        exception when invalid_parameter_value then null;
        end;
    end loop;
    select jsonb_agg('bound-' || value || '@example.invalid') into oversized from generate_series(1, 33) value;
    begin
        perform public.add_onboarding_emails(oversized);
        raise exception 'Unbounded onboarding batch accepted';
    exception when invalid_parameter_value then null;
    end;
    reset role;

    if exists (select 1 from public.onboarding_contact_emails where email = 'onboarding-atomic@example.invalid') then
        raise exception 'Invalid onboarding batch partially saved';
    end if;
    if (select count(*) from public.onboarding_contact_emails where email like 'onboarding-%@example.invalid') <> 2 then
        raise exception 'Onboarding append or deduplication failed';
    end if;
    if exists (select 1 from public.feedback_contact_emails where email like 'onboarding-%@example.invalid') then
        raise exception 'Onboarding write changed the connector-feedback table';
    end if;

    perform set_config('request.jwt.claims', jsonb_build_object('sub', second_user)::text, true);
    set local role authenticated;
    perform public.add_onboarding_emails('["onboarding-first@example.invalid"]');
    reset role;
    delete from auth.users where id in (first_user, second_user);
    set local role authenticated;
    begin
        perform public.add_onboarding_emails('["deleted@example.invalid"]');
        raise exception 'Deleted identity can submit onboarding contacts';
    exception when insufficient_privilege then null;
    end;
    reset role;
    if (select count(*) from public.onboarding_contact_emails where email like 'onboarding-%@example.invalid') <> 2 then
        raise exception 'Identity deletion removed contacts or cross-installation deduplication failed';
    end if;

    perform set_config('request.jwt.claims', '{}', true);
    set local role authenticated;
    begin
        perform public.add_onboarding_emails('["missing@example.invalid"]');
        raise exception 'Missing identity accepted';
    exception when insufficient_privilege then null;
    end;
    reset role;
    set local role anon;
    begin
        perform public.add_onboarding_emails('["unauthenticated@example.invalid"]');
        raise exception 'Unauthenticated onboarding write accepted';
    exception when insufficient_privilege then null;
    end;
    begin
        perform email from public.onboarding_contact_emails;
        raise exception 'Unauthenticated onboarding read accepted';
    exception when insufficient_privilege then null;
    end;
    reset role;
end;
$$;
select 'PASS: onboarding email-only schema, separate table, atomic appends, deduplication, access controls and retention' as onboarding_checks;

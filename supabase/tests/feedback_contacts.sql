-- Run in a transaction and roll back. Uses disposable identities and example.invalid addresses.
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
    where table_schema = 'public' and table_name = 'feedback_contact_emails';
    if fields is distinct from array['email'] then raise exception 'Contact list contains non-email fields'; end if;
    if to_regclass('public.connected_email_accounts') is not null then
        raise exception 'Legacy metadata storage remains available';
    end if;
    if not exists (select 1 from pg_class where oid = 'public.feedback_contact_emails'::regclass
                   and relrowsecurity and relforcerowsecurity) then
        raise exception 'Feedback list must force RLS';
    end if;

    insert into auth.users(id, aud, role, is_anonymous)
    values (first_user, 'authenticated', 'authenticated', true),
           (second_user, 'authenticated', 'authenticated', true);

    perform set_config('request.jwt.claims', jsonb_build_object('sub', first_user)::text, true);
    set local role authenticated;
    perform public.add_feedback_emails('["feedback-first@example.invalid", "feedback-first@example.invalid"]');
    perform public.add_feedback_emails('["feedback-second@example.invalid"]');
    perform public.sync_connected_email_accounts('[{"engine":"chatgpt","provider":"gmail","connection_key":"discard-me","email":"feedback-legacy@example.invalid","reported_via":"connector_profile","consent_version":1}]');
    perform public.sync_connected_email_accounts('[]');
    begin
        perform email from public.feedback_contact_emails;
        raise exception 'Client can read the contact list';
    exception when insufficient_privilege then null;
    end;
    begin
        insert into public.feedback_contact_emails values ('direct@example.invalid');
        raise exception 'Client can bypass the validated RPC';
    exception when insufficient_privilege then null;
    end;
    begin
        update public.feedback_contact_emails set email = 'changed@example.invalid'
        where email = 'feedback-first@example.invalid';
        raise exception 'Client can edit another contact';
    exception when insufficient_privilege then null;
    end;
    begin
        delete from public.feedback_contact_emails where email = 'feedback-first@example.invalid';
        raise exception 'Client can delete contacts';
    exception when insufficient_privilege then null;
    end;

    foreach invalid in array array[
        null::jsonb, 'null'::jsonb, '{}'::jsonb, '[]'::jsonb,
        '[{"email":"nested@example.invalid","provider":"gmail"}]'::jsonb,
        '[123]'::jsonb, '[null]'::jsonb, '[true]'::jsonb,
        '["Case@example.invalid"]'::jsonb, '[" spaced@example.invalid"]'::jsonb,
        '["valid-but-atomic@example.invalid","invalid"]'::jsonb,
        '["line\nbreak@example.invalid"]'::jsonb,
        jsonb_build_array(repeat('a', 255) || '@example.invalid')
    ] loop
        begin
            perform public.add_feedback_emails(invalid);
            raise exception 'Invalid contact payload was accepted';
        exception when invalid_parameter_value then null;
        end;
    end loop;
    begin
        perform public.sync_connected_email_accounts('[{"email":"legacy-atomic@example.invalid"},{"email":"invalid"}]');
        raise exception 'Legacy invalid batch accepted';
    exception when invalid_parameter_value then null;
    end;
    begin
        perform public.sync_connected_email_accounts('[{"email":"unknown-field@example.invalid","message_body":"not-allowed"}]');
        raise exception 'Unexpected legacy field accepted';
    exception when invalid_parameter_value then null;
    end;
    select jsonb_agg('bound-' || value || '@example.invalid') into oversized from generate_series(1, 33) value;
    begin
        perform public.add_feedback_emails(oversized);
        raise exception 'Unbounded contact batch was accepted';
    exception when invalid_parameter_value then null;
    end;
    reset role;

    if exists (select 1 from public.feedback_contact_emails where email in ('valid-but-atomic@example.invalid','legacy-atomic@example.invalid','unknown-field@example.invalid')) then
        raise exception 'Invalid batch partially saved';
    end if;
    if (select count(*) from public.feedback_contact_emails where email like 'feedback-%@example.invalid') <> 3 then
        raise exception 'Append or deduplication failed';
    end if;

    perform set_config('request.jwt.claims', jsonb_build_object('sub', second_user)::text, true);
    set local role authenticated;
    perform public.add_feedback_emails('["feedback-first@example.invalid"]');
    perform public.delete_connected_email_identity();
    begin
        perform public.add_feedback_emails('["deleted-identity@example.invalid"]');
        raise exception 'Deleted identity can still submit contacts';
    exception when insufficient_privilege then null;
    end;
    reset role;
    delete from auth.users where id = first_user;
    if (select count(*) from public.feedback_contact_emails where email like 'feedback-%@example.invalid') <> 3 then
        raise exception 'Identity deletion removed contacts or cross-installation deduplication failed';
    end if;

    perform set_config('request.jwt.claims', '{}', true);
    set local role authenticated;
    begin
        perform public.add_feedback_emails('["missing-identity@example.invalid"]');
        raise exception 'Missing identity accepted';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.sync_connected_email_accounts('[{"email":"unauthenticated-legacy@example.invalid"}]');
        raise exception 'Unauthenticated legacy write accepted';
    exception when insufficient_privilege then null;
    end;
    reset role;
    set local role anon;
    begin
        perform public.add_feedback_emails('["unauthenticated@example.invalid"]');
        raise exception 'Unauthenticated write accepted';
    exception when insufficient_privilege then null;
    end;
    begin
        perform email from public.feedback_contact_emails;
        raise exception 'Unauthenticated read accepted';
    exception when insufficient_privilege then null;
    end;
    reset role;
end;
$$;
select 'PASS: email-only schema, legacy compatibility without metadata storage, atomic appends, deduplication, read/write denial, retained contacts' as feedback_checks;

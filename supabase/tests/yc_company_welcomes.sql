-- Run locally inside a transaction and roll back. These companies and founders are synthetic.
do $$
declare
    published_id uuid := gen_random_uuid();
    hidden_id uuid := gen_random_uuid();
    founder_id uuid := gen_random_uuid();
    payload jsonb;
    relation text;
    forbidden text;
    input text;
begin
    insert into public.yc_companies (id, source_id, name, website, source_url, welcome_line, published, reviewed_at)
    values (published_id, 'welcome-fixture', 'Fixture Company', 'https://fixture.example',
            'https://fixture.example/about', 'Keep your customer follow-ups moving.', true, now()),
           (hidden_id, 'hidden-fixture', 'Unpublished Company', 'https://hidden.example',
            'https://hidden.example/about', 'This must stay private.', false, null);
    insert into public.yc_company_domains (domain, company_id, reviewed_at, source_url)
    values ('fixture.example', published_id, now(), 'https://fixture.example'),
           ('alias.example', published_id, now(), 'https://fixture.example'),
           ('hidden.example', hidden_id, now(), 'https://hidden.example');
    insert into public.yc_founders (id, source_id, first_name, last_name, source_url)
    values (founder_id, 'synthetic-founder', 'Private', 'Fixture', 'https://fixture.example/about');
    insert into public.yc_founder_companies values (founder_id, published_id, true);

    foreach relation in array array['yc_companies','yc_company_domains','yc_founders','yc_founder_companies',
                                   'yc_welcome_presentation'] loop
        if not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                       where n.nspname='public' and c.relname=relation and c.relrowsecurity and c.relforcerowsecurity) then
            raise exception 'Missing forced RLS';
        end if;
        foreach forbidden in array array['SELECT','INSERT','UPDATE','DELETE'] loop
            if has_table_privilege('anon', 'public.' || relation, forbidden)
               or has_table_privilege('authenticated', 'public.' || relation, forbidden) then
                raise exception 'Client has direct reference-table privileges';
            end if;
        end loop;
    end loop;

    set local role anon;
    payload := public.resolve_yc_company_welcome('fixture.example');
    if payload is null or payload->>'company_name' <> 'Fixture Company'
       or payload - array['company_name','welcome_line','logo_path','content_version','attribution_line'] <> '{}'::jsonb
       or (select count(*) from jsonb_object_keys(payload)) <> 5 then
        raise exception 'Incorrect or excessive public payload';
    end if;
    if public.resolve_yc_company_welcome('alias.example') is distinct from payload then
        raise exception 'Reviewed domain alias did not match';
    end if;
    foreach input in array array[null::text,'','hidden.example','unknown.example','gmail.com',
        'FIXTURE.EXAMPLE',' fixture.example','fixture.example.attacker.example','sub.fixture.example',
        'reader@fixture.example','https://fixture.example','fixture.example/','%.example',
        repeat('a',254), E'fixture.example\n'] loop
        if public.resolve_yc_company_welcome(input) is not null then
            raise exception 'Unpublished, malformed, shared or inexact domain matched';
        end if;
    end loop;
    begin
        perform first_name from public.yc_founders;
        raise exception 'Anonymous client read founders';
    exception when insufficient_privilege then null;
    end;
    reset role;
    set local role authenticated;
    if public.resolve_yc_company_welcome('fixture.example') is distinct from payload then
        raise exception 'Authenticated resolver differs from public resolver';
    end if;
    begin
        perform email from public.onboarding_contact_emails;
        raise exception 'Welcome flow exposed contacts';
    exception when insufficient_privilege then null;
    end;
    reset role;

    -- Server-managed presentation copy is optional and shared across matched companies.
    delete from public.yc_welcome_presentation;
    if public.resolve_yc_company_welcome('fixture.example')->>'attribution_line' is not null then
        raise exception 'Missing presentation row broke optional footer';
    end if;
    insert into public.yc_welcome_presentation (attribution_line) values ('Created by the fixture team');
    set local role anon;
    if public.resolve_yc_company_welcome('fixture.example')->>'attribution_line'
        is distinct from 'Created by the fixture team' then
        raise exception 'Public resolver did not include configured footer';
    end if;
    begin
        perform attribution_line from public.yc_welcome_presentation;
        raise exception 'Anonymous client read presentation table directly';
    exception when insufficient_privilege then null;
    end;
    reset role;
    update public.yc_welcome_presentation set attribution_line='Updated fixture attribution';
    if public.resolve_yc_company_welcome('alias.example')->>'attribution_line'
        is distinct from 'Updated fixture attribution' then
        raise exception 'Updated footer was not reflected in alias lookup';
    end if;
    begin
        insert into public.yc_welcome_presentation (singleton, attribution_line) values (false, 'Extra row');
        raise exception 'Multiple presentation rows accepted';
    exception when check_violation then null;
    end;
    foreach input in array array['', ' padded ', repeat('a',141), E'Hidden\nline'] loop
        begin
            update public.yc_welcome_presentation set attribution_line=input;
            raise exception 'Invalid attribution accepted';
        exception when check_violation then null;
        end;
    end loop;

    begin
        insert into public.yc_company_domains values ('gmail.com', published_id, now(), 'https://fixture.example');
        raise exception 'Shared mailbox provider accepted';
    exception when check_violation then null;
    end;
    begin
        insert into public.yc_company_domains values ('fixture.example', hidden_id, now(), 'https://hidden.example');
        raise exception 'Ambiguous domain accepted';
    exception when unique_violation then null;
    end;
    begin
        update public.yc_companies set published=true where id=hidden_id;
        raise exception 'Unreviewed company published';
    exception when check_violation then null;
    end;
    update public.yc_companies set website=null, reviewed_at=now(), source_status='Inactive' where id=hidden_id;
    begin
        update public.yc_companies set published=true where id=hidden_id;
        raise exception 'Company without a website published';
    exception when check_violation then null;
    end;
    begin
        update public.yc_companies set logo_path='../private.png' where id=published_id;
        raise exception 'Untrusted logo path accepted';
    exception when check_violation then null;
    end;
    update public.yc_companies set published=false where id=published_id;
    if public.resolve_yc_company_welcome('fixture.example') is not null then
        raise exception 'Unpublishing did not disable welcome';
    end if;

    if exists (select 1 from information_schema.columns where table_schema='public'
               and table_name in ('onboarding_contact_emails','feedback_contact_emails') and column_name <> 'email') then
        raise exception 'Welcome changed email-only contacts';
    end if;
end;
$$;
select 'PASS: public company-only lookup, private founder tables, exact reviewed domains, publication controls and contact separation' as welcome_checks;

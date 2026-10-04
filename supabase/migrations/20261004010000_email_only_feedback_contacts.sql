-- The founder-feedback list contains one value per contact: an email address.
-- Apply before shipping the client that calls add_feedback_emails. The legacy endpoint
-- extracts email addresses only, keeping existing builds compatible without storing metadata.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

lock table public.connected_email_accounts in access exclusive mode;

create table public.feedback_contact_emails (
    email text primary key check (
        octet_length(email) between 3 and 254
        and email = lower(btrim(email))
        and email ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
        and email !~ '[[:cntrl:]]'
    )
);

alter table public.feedback_contact_emails enable row level security;
alter table public.feedback_contact_emails force row level security;
revoke all on table public.feedback_contact_emails from public, anon, authenticated;
grant select, insert, update, delete on table public.feedback_contact_emails to service_role;

-- Preserve addresses, deduplicating across connectors and installations. The new table has
-- no owner, connector, AI provider, source, consent version, row ID, or timestamp columns.
insert into public.feedback_contact_emails (email)
select distinct email from public.connected_email_accounts;

do $$
begin
    if (select count(*) from public.feedback_contact_emails) <>
       (select count(distinct email) from public.connected_email_accounts) then
        raise exception 'Contact migration did not preserve every distinct email address';
    end if;
end;
$$;

drop function public.sync_connected_email_accounts(jsonb);
drop table public.connected_email_accounts;
drop function public.touch_connected_email_account();

-- Authentication authorizes this write only. Neither its ID nor its token is stored in the list.
-- Clients cannot read, update, or delete contacts, and receive no address-existence response.
create function public.add_feedback_emails(emails jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null or not exists (select 1 from auth.users where id = auth.uid()) then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if emails is null or jsonb_typeof(emails) <> 'array' then
        raise exception 'Expected email addresses' using errcode = '22023';
    end if;
    if jsonb_array_length(emails) not between 1 and 32 then
        raise exception 'Expected between 1 and 32 email addresses' using errcode = '22023';
    end if;
    if exists (select 1 from jsonb_array_elements(emails) value where jsonb_typeof(value) <> 'string') then
        raise exception 'Only email strings are accepted' using errcode = '22023';
    end if;
    if exists (
        select 1 from jsonb_array_elements_text(emails) value
        where octet_length(value) not between 3 and 254
           or value <> lower(btrim(value))
           or value !~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
           or value ~ '[[:cntrl:]]'
    ) then
        raise exception 'Invalid email address' using errcode = '22023';
    end if;

    insert into public.feedback_contact_emails (email)
    select distinct value from jsonb_array_elements_text(emails) value
    on conflict (email) do nothing;
end;
$$;
revoke all on function public.add_feedback_emails(jsonb) from public, anon;
grant execute on function public.add_feedback_emails(jsonb) to authenticated;

-- Older builds still send their connector-shaped payload. Discard everything except email
-- before calling the same email-only writer. An empty legacy snapshot never deletes contacts.
create function public.sync_connected_email_accounts(accounts jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
declare
    addresses jsonb;
begin
    if auth.uid() is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if accounts is null or jsonb_typeof(accounts) <> 'array' then
        raise exception 'Expected email accounts' using errcode = '22023';
    end if;
    if jsonb_array_length(accounts) > 32 then
        raise exception 'Too many email accounts' using errcode = '22023';
    end if;
    if jsonb_array_length(accounts) = 0 then return; end if;
    if exists (
        select 1 from jsonb_array_elements(accounts) account
        where jsonb_typeof(account) <> 'object'
           or not (account ? 'email')
           or (account - array['engine','provider','connection_key','email','reported_via','consent_version']) <> '{}'::jsonb
    ) then
        raise exception 'Invalid account fields' using errcode = '22023';
    end if;
    select jsonb_agg(account->'email') into addresses from jsonb_array_elements(accounts) account;
    perform public.add_feedback_emails(addresses);
end;
$$;
revoke all on function public.sync_connected_email_accounts(jsonb) from public, anon;
grant execute on function public.sync_connected_email_accounts(jsonb) to authenticated;

comment on table public.feedback_contact_emails is
    'Founder-feedback contact list. Email addresses only, without connector or installation metadata.';

commit;

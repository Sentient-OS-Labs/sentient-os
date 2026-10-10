-- Keep manually submitted onboarding addresses separate from connector-discovered contacts.
-- Apply before shipping the onboarding email prompt. No existing contacts are copied or changed.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create table public.onboarding_contact_emails (
    email text primary key check (
        octet_length(email) between 3 and 254
        and email = lower(btrim(email))
        and email ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
        and email !~ '[[:cntrl:]]'
    )
);

alter table public.onboarding_contact_emails enable row level security;
alter table public.onboarding_contact_emails force row level security;
revoke all on table public.onboarding_contact_emails from public, anon, authenticated;
grant select, insert, update, delete on table public.onboarding_contact_emails to service_role;

-- The anonymous Auth session authorizes writes without being attached to a contact row.
-- App clients cannot read the list or distinguish a new address from a duplicate.
create function public.add_onboarding_emails(emails jsonb)
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

    insert into public.onboarding_contact_emails (email)
    select distinct value from jsonb_array_elements_text(emails) value
    on conflict (email) do nothing;
end;
$$;
revoke all on function public.add_onboarding_emails(jsonb) from public, anon;
grant execute on function public.add_onboarding_emails(jsonb) to authenticated;

comment on table public.onboarding_contact_emails is
    'Manually submitted onboarding contact addresses, without connector or installation metadata.';

commit;

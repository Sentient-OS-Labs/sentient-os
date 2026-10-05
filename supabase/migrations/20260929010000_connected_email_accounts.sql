-- Each anonymous Supabase Auth identity belongs to one installation. An email address is
-- contact metadata, never an authentication credential or proof of mailbox ownership.
begin;

create table public.connected_email_accounts (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    engine text not null check (engine in ('chatgpt', 'claude')),
    provider text not null check (provider in ('gmail', 'outlook')),
    connection_key text not null check (length(connection_key) between 1 and 256),
    email text not null check (
        octet_length(email) between 3 and 254
        and email = lower(btrim(email))
        and email ~ '^[^[:space:]@<>]+@[^[:space:]@<>]+\.[^[:space:]@<>]+$'
    ),
    reported_via text not null check (reported_via in ('connector_profile', 'user_entered')),
    consent_version integer not null check (consent_version = 1),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (owner_id, engine, provider, connection_key)
);

alter table public.connected_email_accounts enable row level security;
alter table public.connected_email_accounts force row level security;
revoke all on table public.connected_email_accounts from public, anon, authenticated;
grant select, delete on table public.connected_email_accounts to authenticated;
grant insert (engine, provider, connection_key, email, reported_via, consent_version)
    on public.connected_email_accounts to authenticated;
grant update (email, reported_via, consent_version)
    on public.connected_email_accounts to authenticated;
grant all on table public.connected_email_accounts to service_role;

create policy "Read own email accounts" on public.connected_email_accounts
    for select to authenticated using ((select auth.uid()) = owner_id);
create policy "Insert own email accounts" on public.connected_email_accounts
    for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy "Update own email accounts" on public.connected_email_accounts
    for update to authenticated using ((select auth.uid()) = owner_id)
    with check ((select auth.uid()) = owner_id);
create policy "Delete own email accounts" on public.connected_email_accounts
    for delete to authenticated using ((select auth.uid()) = owner_id);

create function public.touch_connected_email_account()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
    new.updated_at := pg_catalog.now();
    return new;
end;
$$;
revoke all on function public.touch_connected_email_account() from public, anon, authenticated;
create trigger connected_email_accounts_updated_at before update
    on public.connected_email_accounts for each row
    execute function public.touch_connected_email_account();

-- Atomic snapshot replacement: RLS and column grants apply inside this invoker function.
-- owner_id is never accepted from the client. An empty snapshot removes only this user's rows.
create function public.sync_connected_email_accounts(accounts jsonb)
returns void language plpgsql security invoker set search_path = '' as $$
declare
    actor uuid := auth.uid();
begin
    if actor is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if accounts is null or jsonb_typeof(accounts) <> 'array' then
        raise exception 'Expected an array' using errcode = '22023';
    end if;
    if jsonb_array_length(accounts) > 32 then
        raise exception 'Too many email accounts' using errcode = '22023';
    end if;
    if exists (
        select 1 from jsonb_array_elements(accounts) a
        where jsonb_typeof(a) <> 'object'
           or not (a ?& array['engine','provider','connection_key','email','reported_via','consent_version'])
           or (a - array['engine','provider','connection_key','email','reported_via','consent_version']) <> '{}'::jsonb
    ) then
        raise exception 'Invalid account fields' using errcode = '22023';
    end if;

    -- Serialize snapshots for the same owner, including empty snapshots.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text, 0));

    insert into public.connected_email_accounts
        (engine, provider, connection_key, email, reported_via, consent_version)
    select x.engine, x.provider, x.connection_key, x.email, x.reported_via, x.consent_version
    from jsonb_to_recordset(accounts) as x(
        engine text, provider text, connection_key text, email text,
        reported_via text, consent_version integer
    )
    on conflict (owner_id, engine, provider, connection_key) do update
        set email = excluded.email,
            reported_via = excluded.reported_via,
            consent_version = excluded.consent_version;

    delete from public.connected_email_accounts a
    where a.owner_id = actor and not exists (
        select 1 from jsonb_to_recordset(accounts) as x(engine text, provider text, connection_key text)
        where x.engine = a.engine and x.provider = a.provider and x.connection_key = a.connection_key
    );
end;
$$;
revoke all on function public.sync_connected_email_accounts(jsonb) from public, anon;
grant execute on function public.sync_connected_email_accounts(jsonb) to authenticated;

-- The sole definer RPC is self-deletion. It has no target-user argument and cannot
-- remove permanent login accounts. Deleting the Auth identity cascades to all its records.
create function public.delete_connected_email_identity()
returns void language plpgsql security definer set search_path = '' as $$
declare
    actor uuid := auth.uid();
begin
    if actor is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    delete from auth.users where id = actor and is_anonymous is true;
end;
$$;
revoke all on function public.delete_connected_email_identity() from public, anon;
grant execute on function public.delete_connected_email_identity() to authenticated;

comment on table public.connected_email_accounts is
    'Connected email addresses disclosed and saved by an installation. Client-reported addresses are not proof of ownership. No mailbox content or provider credentials.';

commit;

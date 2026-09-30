-- Reject duplicate entries before an upsert, preserving predictable client errors.
begin;
create or replace function public.sync_connected_email_accounts(accounts jsonb)
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

    if exists (
        select 1 from jsonb_to_recordset(accounts) as x(engine text, provider text, connection_key text)
        group by engine, provider, connection_key having count(*) > 1
    ) then
        raise exception 'Duplicate connection keys' using errcode = '22023';
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

commit;

-- Hosted inference accounting. Only the gateway's service role can call the ledger.
-- The migration enables no funded service: operators must explicitly fund and enable policy.
-- Contract and local verification: HostedInference/README.md.
create table public.hosted_inference_policy (
    singleton boolean primary key default true check (singleton),
    enabled boolean not null default false,
    version integer not null default 1 check (version > 0),
    daily_seconds integer not null default 3600 check (daily_seconds = 3600),
    lease_seconds integer not null default 45 check (lease_seconds between 15 and 120),
    user_daily_microusd bigint not null default 0 check (user_daily_microusd >= 0),
    background_daily_microusd bigint not null default 0 check (background_daily_microusd >= 0),
    bootstrap_lifetime_microusd bigint not null default 0 check (bootstrap_lifetime_microusd >= 0),
    global_daily_microusd bigint not null default 0 check (global_daily_microusd >= 0),
    global_monthly_microusd bigint not null default 0 check (global_monthly_microusd >= 0),
    requests_per_minute integer not null default 30 check (requests_per_minute between 1 and 120),
    probes_per_minute integer not null default 120 check (probes_per_minute between 1 and 300),
    runs_per_day integer not null default 100 check (runs_per_day between 1 and 1000)
);
insert into public.hosted_inference_policy(singleton) values (true);

create table public.hosted_inference_principals (
    principal_id uuid primary key references auth.users(id) on delete cascade,
    disabled boolean not null default false,
    bootstrap_microusd bigint not null default 0 check (bootstrap_microusd >= 0),
    created_at timestamptz not null default now()
);
create table public.hosted_inference_daily (
    principal_id uuid not null references public.hosted_inference_principals(principal_id) on delete cascade,
    day date not null,
    active_ms bigint not null default 0 check (active_ms >= 0),
    charged_microusd bigint not null default 0 check (charged_microusd >= 0),
    background_microusd bigint not null default 0 check (background_microusd >= 0),
    runs integer not null default 0,
    primary key (principal_id, day)
);
create table public.hosted_inference_global (
    bucket text primary key,
    charged_microusd bigint not null default 0 check (charged_microusd >= 0)
);
create table public.hosted_inference_runs (
    id uuid primary key default gen_random_uuid(),
    principal_id uuid not null references public.hosted_inference_principals(principal_id) on delete cascade,
    token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
    purpose text not null check (purpose in ('sidekick','knowledge_bootstrap','knowledge_update','proactive','utility')),
    model text not null check (length(model) between 1 and 200),
    phase text not null default 'running' check (phase in ('running','waiting_for_user','completed','expired')),
    created_at timestamptz not null default now(),
    last_accounted_at timestamptz not null default now(),
    lease_expires_at timestamptz not null,
    minute_window timestamptz not null default now(),
    minute_requests integer not null default 0,
    minute_probes integer not null default 0
);
-- One foreground task across devices, and one bounded background job per principal.
create unique index hosted_one_foreground on public.hosted_inference_runs(principal_id)
    where purpose = 'sidekick' and phase in ('running','waiting_for_user');
create unique index hosted_one_background on public.hosted_inference_runs(principal_id)
    where purpose <> 'sidekick' and phase in ('running','waiting_for_user');
create table public.hosted_inference_requests (
    id uuid primary key default gen_random_uuid(),
    run_id uuid not null references public.hosted_inference_runs(id) on delete cascade,
    idempotency_key text not null check (length(idempotency_key) between 1 and 128),
    request_hash text not null check (request_hash ~ '^[a-f0-9]{64}$'),
    day date not null,
    month text not null,
    reserve_microusd bigint not null check (reserve_microusd >= 0),
    charged_microusd bigint not null check (charged_microusd >= 0),
    status text not null default 'reserved' check (status in ('reserved','completed','cancelled','unknown','rejected','timeout')),
    usage jsonb not null default '{}',
    created_at timestamptz not null default now(),
    settled_at timestamptz,
    unique (run_id, idempotency_key)
);
create unique index hosted_one_request on public.hosted_inference_requests(run_id) where status = 'reserved';

alter table public.hosted_inference_policy enable row level security;
alter table public.hosted_inference_principals enable row level security;
alter table public.hosted_inference_daily enable row level security;
alter table public.hosted_inference_global enable row level security;
alter table public.hosted_inference_runs enable row level security;
alter table public.hosted_inference_requests enable row level security;
revoke all on public.hosted_inference_policy, public.hosted_inference_principals,
    public.hosted_inference_daily, public.hosted_inference_global,
    public.hosted_inference_runs, public.hosted_inference_requests from public, anon, authenticated;
grant all on public.hosted_inference_policy, public.hosted_inference_principals,
    public.hosted_inference_daily, public.hosted_inference_global,
    public.hosted_inference_runs, public.hosted_inference_requests to service_role;

-- Charge each UTC day separately, bounded by the last server-issued lease. Client timestamps
-- are never accepted. All callers hold the principal advisory lock before entering.
create function public.hosted_inference_clock(run_id uuid, at_time timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
    r public.hosted_inference_runs%rowtype;
    p public.hosted_inference_policy%rowtype;
    cursor_at timestamptz;
    stop_at timestamptz;
    segment_end timestamptz;
    current_day date;
    remaining_ms bigint;
    elapsed_ms bigint;
begin
    select * into r from public.hosted_inference_runs where id = run_id for update;
    if not found or r.phase in ('completed','expired') then return; end if;
    select * into p from public.hosted_inference_policy where singleton;
    if r.phase = 'running' and r.purpose = 'sidekick' then
        cursor_at := r.last_accounted_at;
        stop_at := least(at_time, r.lease_expires_at);
        while cursor_at < stop_at loop
            current_day := (cursor_at at time zone 'UTC')::date;
            segment_end := least(stop_at, (current_day + 1)::timestamp at time zone 'UTC');
            insert into public.hosted_inference_daily(principal_id,day) values(r.principal_id,current_day) on conflict do nothing;
            select greatest(0, p.daily_seconds * 1000::bigint - active_ms) into remaining_ms
                from public.hosted_inference_daily where principal_id = r.principal_id and day = current_day for update;
            -- Never discard fractional time while advancing last_accounted_at. Flooring
            -- each interval would let frequent sub-millisecond calls avoid all charging.
            elapsed_ms := greatest(0, ceil(extract(epoch from (segment_end - cursor_at))*1000)::bigint);
            update public.hosted_inference_daily set active_ms = active_ms + least(elapsed_ms, remaining_ms)
                where principal_id = r.principal_id and day = current_day;
            if elapsed_ms >= remaining_ms then
                update public.hosted_inference_runs set phase = 'expired',
                    lease_expires_at = cursor_at + remaining_ms * interval '1 millisecond',
                    last_accounted_at = cursor_at + remaining_ms * interval '1 millisecond' where id = run_id;
                return;
            end if;
            cursor_at := segment_end;
        end loop;
    end if;
    update public.hosted_inference_runs set last_accounted_at = greatest(last_accounted_at,least(at_time, lease_expires_at)),
        phase = case when lease_expires_at <= at_time then 'expired' else phase end where id = run_id;
end;
$$;
revoke all on function public.hosted_inference_clock(uuid,timestamptz) from public, anon, authenticated;

create function public.hosted_inference_snapshot(principal uuid, at_time timestamptz, run_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    p public.hosted_inference_policy%rowtype;
    d public.hosted_inference_daily%rowtype;
    r public.hosted_inference_runs%rowtype;
    result jsonb;
    today date := (at_time at time zone 'UTC')::date;
begin
    select * into p from public.hosted_inference_policy where singleton;
    select * into d from public.hosted_inference_daily where principal_id = principal and day = today;
    result := jsonb_build_object('daily_limit_seconds', p.daily_seconds,
        'used_seconds', coalesce(d.active_ms,0)::numeric/1000,
        'remaining_seconds', greatest(0,p.daily_seconds-coalesce(d.active_ms,0)::numeric/1000),
        'reset_at', (today+1)::timestamp at time zone 'UTC', 'server_time',at_time, 'policy_version',p.version);
    if run_id is not null then
        select * into r from public.hosted_inference_runs where id = run_id;
        result := result || jsonb_build_object('run_id',r.id,'purpose',r.purpose,'model',r.model,
            'phase',r.phase,'lease_expires_at',r.lease_expires_at);
    end if;
    return result;
end;
$$;
revoke all on function public.hosted_inference_snapshot(uuid,timestamptz,uuid) from public, anon, authenticated;

-- A single gateway-only RPC keeps reservations and daily/global balances in one transaction.
-- JSON error results deliberately commit elapsed-time accounting and failed admission state.
create function public.hosted_inference(operation text, args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    p public.hosted_inference_policy%rowtype;
    principal uuid;
    principal_row public.hosted_inference_principals%rowtype;
    r public.hosted_inference_runs%rowtype;
    q public.hosted_inference_requests%rowtype;
    d public.hosted_inference_daily%rowtype;
    at_time timestamptz := clock_timestamp();
    today date := (at_time at time zone 'UTC')::date;
    month_key text := to_char(at_time at time zone 'UTC','YYYY-MM');
    reset_at timestamptz := (today+1)::timestamp at time zone 'UTC';
    cost bigint;
    actual bigint;
    delta bigint;
    global_day bigint;
    global_month bigint;
    other_id uuid;
    chosen_purpose text;
    result jsonb;
    error_details jsonb;
begin
    select * into p from public.hosted_inference_policy where singleton;
    if not found then return jsonb_build_object('error','service_disabled','status',503); end if;
    if operation in ('usage','create') then
        principal := (args->>'principal_id')::uuid;
        if principal is null or not exists(select 1 from auth.users where id = principal) then
            return jsonb_build_object('error','authentication_required','status',401);
        end if;
    else
        select * into r from public.hosted_inference_runs where token_hash = args->>'token_hash';
        if not found or (args ? 'run_id' and r.id::text <> args->>'run_id') then
            return jsonb_build_object('error','authentication_required','status',401);
        end if;
        principal := r.principal_id;
    end if;
    perform pg_advisory_xact_lock(hashtextextended(principal::text,29100001));
    -- A queued call must account from the time it actually owns this principal. Using a
    -- timestamp captured before the lock can backdate a later heartbeat or cross UTC days.
    at_time := clock_timestamp();
    today := (at_time at time zone 'UTC')::date;
    month_key := to_char(at_time at time zone 'UTC','YYYY-MM');
    reset_at := (today+1)::timestamp at time zone 'UTC';
    insert into public.hosted_inference_principals(principal_id) values(principal) on conflict do nothing;
    select * into principal_row from public.hosted_inference_principals where principal_id = principal for update;
    if principal_row.disabled and operation <> 'settle' then
        return jsonb_build_object('error','authentication_required','status',403);
    end if;
    -- Reap stale leases on any authenticated call. Outstanding money reservations remain charged.
    for other_id in select id from public.hosted_inference_runs
        where principal_id = principal and phase in ('running','waiting_for_user') loop
        perform public.hosted_inference_clock(other_id,at_time);
    end loop;
    if r.id is not null then select * into r from public.hosted_inference_runs where id = r.id for update; end if;
    insert into public.hosted_inference_daily(principal_id,day) values(principal,today) on conflict do nothing;
    select * into d from public.hosted_inference_daily where principal_id = principal and day = today for update;
    error_details := public.hosted_inference_snapshot(principal,at_time,r.id);
    if operation = 'usage' then
        if not p.enabled or least(p.user_daily_microusd,p.global_daily_microusd,p.global_monthly_microusd)<=0 then
            return jsonb_build_object('error','service_disabled','status',503,'details',error_details);
        end if;
        select charged_microusd into global_day from public.hosted_inference_global where bucket='day:'||today::text;
        select charged_microusd into global_month from public.hosted_inference_global where bucket='month:'||month_key;
        if coalesce(global_day,0)>=p.global_daily_microusd or coalesce(global_month,0)>=p.global_monthly_microusd then
            return jsonb_build_object('error','service_budget_reached','status',503,'details',error_details);
        end if;
        if d.charged_microusd>=p.user_daily_microusd then
            return jsonb_build_object('error','usage_limit_reached','status',429,'details',error_details);
        end if;
        return error_details;
    end if;

    -- Settlement is allowed after cancellation, expiration, midnight and a service kill switch.
    if operation = 'settle' then
        select * into q from public.hosted_inference_requests where id = (args->>'request_id')::uuid and run_id = r.id for update;
        if not found then return jsonb_build_object('error','invalid_request','status',404); end if;
        if q.settled_at is not null then return jsonb_build_object('request_id',q.id,'status',q.status); end if;
        if args->>'status' not in ('completed','cancelled','unknown','rejected','timeout') then
            return jsonb_build_object('error','invalid_request','status',400);
        end if;
        actual := coalesce((args->>'actual_microusd')::bigint,q.reserve_microusd);
        if actual < 0 then return jsonb_build_object('error','invalid_request','status',400); end if;
        if jsonb_typeof(coalesce(args->'usage','{}')) <> 'object' or
            (coalesce(args->'usage','{}') - array['input_tokens','output_tokens','cache_creation_input_tokens','cache_read_input_tokens']) <> '{}'::jsonb then
            return jsonb_build_object('error','invalid_request','status',400);
        end if;
        delta := actual-q.charged_microusd;
        -- Always lock aggregate buckets in day/month order. A late receipt settles its original
        -- reservation bucket, not the current UTC day.
        perform 1 from public.hosted_inference_global where bucket = 'day:'||q.day::text for update;
        perform 1 from public.hosted_inference_global where bucket = 'month:'||q.month for update;
        update public.hosted_inference_global set charged_microusd=charged_microusd+delta
            where bucket in ('day:'||q.day::text,'month:'||q.month);
        update public.hosted_inference_daily set charged_microusd=charged_microusd+delta,
            background_microusd=background_microusd+case when r.purpose not in ('sidekick','knowledge_bootstrap') then delta else 0 end
            where principal_id=principal and day=q.day;
        if r.purpose='knowledge_bootstrap' then
            update public.hosted_inference_principals set bootstrap_microusd=bootstrap_microusd+delta where principal_id=principal;
        end if;
        update public.hosted_inference_requests set charged_microusd=actual,status=args->>'status',
            usage=coalesce(args->'usage','{}'),settled_at=at_time where id=q.id;
        return jsonb_build_object('request_id',q.id,'status',args->>'status');
    end if;
    if operation='finish' then
        update public.hosted_inference_runs set phase='completed',lease_expires_at=at_time,last_accounted_at=at_time where id=r.id;
        return public.hosted_inference_snapshot(principal,at_time,r.id);
    end if;
    if not p.enabled then return jsonb_build_object('error','service_disabled','status',503,'details',error_details); end if;

    if operation='create' then
        chosen_purpose := args->>'purpose';
        if chosen_purpose not in ('sidekick','knowledge_bootstrap','knowledge_update','proactive','utility') or chosen_purpose is null
            or coalesce(args->>'model','')='' or coalesce(args->>'token_hash','') !~ '^[a-f0-9]{64}$' then
            return jsonb_build_object('error','invalid_purpose','status',400);
        end if;
        if d.runs >= p.runs_per_day then return jsonb_build_object('error','usage_limit_reached','status',429,'details',error_details); end if;
        if chosen_purpose='sidekick' and d.active_ms >= p.daily_seconds*1000::bigint then
            return jsonb_build_object('error','daily_time_exhausted','status',429,'details',error_details);
        end if;
        if exists(select 1 from public.hosted_inference_runs where principal_id=principal and phase in ('running','waiting_for_user')
            and ((chosen_purpose='sidekick') = (hosted_inference_runs.purpose='sidekick'))) then
            return jsonb_build_object('error','run_busy','status',409,'details',error_details);
        end if;
        insert into public.hosted_inference_runs(principal_id,token_hash,purpose,model,last_accounted_at,lease_expires_at)
            values(principal,args->>'token_hash',chosen_purpose,args->>'model',at_time,
                at_time+least(p.lease_seconds,case when chosen_purpose='sidekick' then greatest(0,p.daily_seconds-d.active_ms::numeric/1000) else p.lease_seconds end)*interval '1 second')
            returning * into r;
        update public.hosted_inference_daily set runs=runs+1 where principal_id=principal and day=today;
        return public.hosted_inference_snapshot(principal,at_time,r.id);
    end if;
    if r.phase in ('completed','expired') then
        return jsonb_build_object('error',case when r.purpose='sidekick' and d.active_ms>=p.daily_seconds*1000::bigint then 'daily_time_exhausted' else 'run_expired' end,
            'status',429,'details',error_details);
    end if;
    if operation='pause' then
        if r.purpose<>'sidekick' then return jsonb_build_object('error','invalid_transition','status',409); end if;
        if exists(select 1 from public.hosted_inference_requests where run_id=r.id and status='reserved') then
            return jsonb_build_object('error','run_busy','status',409,'details',error_details);
        end if;
        update public.hosted_inference_runs set phase='waiting_for_user',last_accounted_at=at_time,
            lease_expires_at=at_time+interval '24 hours' where id=r.id;
        return public.hosted_inference_snapshot(principal,at_time,r.id);
    end if;
    if operation='resume' then
        if r.phase='running' then return error_details; end if;
        if r.phase<>'waiting_for_user' then return jsonb_build_object('error','invalid_transition','status',409); end if;
        if d.active_ms>=p.daily_seconds*1000::bigint then return jsonb_build_object('error','daily_time_exhausted','status',429,'details',error_details); end if;
        update public.hosted_inference_runs set phase='running',last_accounted_at=at_time,
            lease_expires_at=at_time+least(p.lease_seconds,p.daily_seconds-d.active_ms::numeric/1000)*interval '1 second' where id=r.id;
        return public.hosted_inference_snapshot(principal,at_time,r.id);
    end if;
    if operation='heartbeat' then
        if r.phase='running' then
            update public.hosted_inference_runs set lease_expires_at=at_time+least(p.lease_seconds,
                case when r.purpose='sidekick' then greatest(0,p.daily_seconds-d.active_ms::numeric/1000) else p.lease_seconds end)*interval '1 second' where id=r.id;
        end if;
        return public.hosted_inference_snapshot(principal,at_time,r.id);
    end if;
    if r.phase<>'running' then return jsonb_build_object('error','run_paused','status',409,'details',error_details); end if;
    if operation='inspect' then return error_details; end if;
    if operation not in ('reserve','probe') then return jsonb_build_object('error','invalid_operation','status',400); end if;
    if r.minute_window <= at_time-interval '1 minute' then
        update public.hosted_inference_runs set minute_window=at_time,minute_requests=0,minute_probes=0 where id=r.id;
        r.minute_requests:=0; r.minute_probes:=0;
    end if;
    if operation='probe' then
        if r.minute_probes>=p.probes_per_minute then return jsonb_build_object('error','request_rate_limited','status',429); end if;
        update public.hosted_inference_runs set minute_probes=minute_probes+1 where id=r.id;
        return error_details;
    end if;
    -- A retried id never dispatches a second provider request, even after settlement.
    select * into q from public.hosted_inference_requests where run_id=r.id and idempotency_key=args->>'idempotency_key';
    if found then
        return jsonb_build_object('error',case when q.request_hash=args->>'request_hash' then 'request_already_dispatched' else 'idempotency_conflict' end,
            'status',409,'details',jsonb_build_object('request_id',q.id,'request_status',q.status));
    end if;
    if exists(select 1 from public.hosted_inference_requests where run_id=r.id and status='reserved') then
        return jsonb_build_object('error','run_busy','status',409,'details',error_details);
    end if;
    if r.minute_requests>=p.requests_per_minute then return jsonb_build_object('error','request_rate_limited','status',429); end if;
    cost := (args->>'reserve_microusd')::bigint;
    if cost is null or cost<=0 or cost>1000000000 then return jsonb_build_object('error','invalid_reservation','status',400); end if;
    if d.charged_microusd+cost>p.user_daily_microusd
        or (r.purpose='knowledge_bootstrap' and principal_row.bootstrap_microusd+cost>p.bootstrap_lifetime_microusd)
        or (r.purpose not in ('sidekick','knowledge_bootstrap') and d.background_microusd+cost>p.background_daily_microusd) then
        return jsonb_build_object('error','usage_limit_reached','status',429,'details',error_details);
    end if;
    insert into public.hosted_inference_global(bucket) values('day:'||today::text),('month:'||month_key) on conflict do nothing;
    select charged_microusd into global_day from public.hosted_inference_global where bucket='day:'||today::text for update;
    select charged_microusd into global_month from public.hosted_inference_global where bucket='month:'||month_key for update;
    if global_day+cost>p.global_daily_microusd or global_month+cost>p.global_monthly_microusd then
        return jsonb_build_object('error','service_budget_reached','status',503,'details',error_details);
    end if;
    insert into public.hosted_inference_requests(run_id,idempotency_key,request_hash,day,month,reserve_microusd,charged_microusd)
        values(r.id,args->>'idempotency_key',args->>'request_hash',today,month_key,cost,cost) returning * into q;
    update public.hosted_inference_daily set charged_microusd=charged_microusd+cost,
        background_microusd=background_microusd+case when r.purpose not in ('sidekick','knowledge_bootstrap') then cost else 0 end
        where principal_id=principal and day=today;
    if r.purpose='knowledge_bootstrap' then
        update public.hosted_inference_principals set bootstrap_microusd=bootstrap_microusd+cost where principal_id=principal;
    end if;
    update public.hosted_inference_global set charged_microusd=charged_microusd+cost where bucket in ('day:'||today::text,'month:'||month_key);
    update public.hosted_inference_runs set minute_requests=minute_requests+1 where id=r.id;
    return jsonb_build_object('request_id',q.id,'reserved_microusd',cost)||error_details;
end;
$$;
revoke all on function public.hosted_inference(text,jsonb) from public, anon, authenticated;
grant execute on function public.hosted_inference(text,jsonb) to service_role;
comment on table public.hosted_inference_requests is
    'Content-free admission and usage ledger. Unsettled requests remain conservatively charged; no prompt, screen or response content is stored.';

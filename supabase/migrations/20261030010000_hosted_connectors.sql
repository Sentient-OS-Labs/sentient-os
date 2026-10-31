-- Server-owned Composio accounts and short-lived connector capabilities. No OAuth tokens or
-- source content belongs here. Installed disabled and unfunded; activation is operator-owned.
create table public.hosted_connector_policy (
  singleton boolean primary key default true check(singleton),
  enabled boolean not null default false,
  pricing_verified boolean not null default false,
  call_microusd bigint not null default 0 check(call_microusd between 0 and 1000000),
  user_daily_calls integer not null default 0 check(user_daily_calls between 0 and 100000),
  background_daily_calls integer not null default 0 check(background_daily_calls between 0 and 100000),
  global_daily_calls bigint not null default 0 check(global_daily_calls >= 0),
  global_monthly_calls bigint not null default 0 check(global_monthly_calls >= 0),
  user_daily_microusd bigint not null default 0 check(user_daily_microusd >= 0),
  global_monthly_microusd bigint not null default 0 check(global_monthly_microusd >= 0),
  requests_per_minute integer not null default 30 check(requests_per_minute between 1 and 300),
  global_requests_per_minute integer not null default 300 check(global_requests_per_minute between 1 and 10000),
  connections_per_user integer not null default 18 check(connections_per_user between 1 and 60)
);
insert into public.hosted_connector_policy(singleton) values(true);
create table public.hosted_connector_users (
  principal_id uuid primary key references auth.users(id) on delete cascade,
  composio_user text not null unique default ('sentient_' || replace(gen_random_uuid()::text,'-','')),
  revision bigint not null default 0,
  created_at timestamptz not null default now()
);
create table public.hosted_connector_accounts (
  id uuid primary key default gen_random_uuid(),
  principal_id uuid not null references public.hosted_connector_users(principal_id) on delete cascade,
  service text not null check(service in ('gmail','google-calendar','google-drive','slack','outlook-mail','outlook-calendar')),
  generation integer not null default 1 check(generation>0),
  upstream_id text unique,
  auth_config text not null,
  label text not null check(length(label) between 1 and 100),
  status text not null default 'connecting' check(status in ('connecting','active','disconnected','disconnect_pending','revocation_pending')),
  created_at timestamptz not null default now()
);
create function public.hosted_connector_revision() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.hosted_connector_users set revision=revision+1 where principal_id=new.principal_id;
  return new;
end;
$$;
revoke all on function public.hosted_connector_revision() from public,anon,authenticated;
create trigger hosted_connector_revision after insert or update on public.hosted_connector_accounts
  for each row execute function public.hosted_connector_revision();
create table public.hosted_connector_attempts (
  id uuid primary key,
  connection_id uuid not null references public.hosted_connector_accounts(id) on delete cascade,
  generation integer not null,
  auth_config text not null,
  state_hash text not null unique check(state_hash ~ '^[a-f0-9]{64}$'),
  upstream_id text,
  status text not null default 'pending' check(status in ('pending','completed','cancelled','failed','expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create unique index hosted_connector_one_attempt on public.hosted_connector_attempts(connection_id) where status='pending';
create table public.hosted_connector_capabilities (
  id uuid primary key,
  token_hash text not null unique check(token_hash ~ '^[a-f0-9]{64}$'),
  run_id uuid not null references public.hosted_inference_runs(id) on delete cascade,
  connection_id uuid not null references public.hosted_connector_accounts(id) on delete cascade,
  generation integer not null,
  mode text not null check(mode in ('read','action')),
  auth_config text not null,
  session_id text unique,
  session_deleted boolean not null default false,
  closed boolean not null default false,
  created_at timestamptz not null default now()
);
create table public.hosted_connector_operations (
  id uuid primary key default gen_random_uuid(),
  capability_id uuid not null references public.hosted_connector_capabilities(id) on delete cascade,
  connection_id uuid not null references public.hosted_connector_accounts(id),
  generation integer not null,
  operation_key uuid not null,
  request_hash text not null check(request_hash ~ '^[a-f0-9]{64}$'),
  tool text not null check(tool ~ '^[a-z_]{1,80}$'),
  is_write boolean not null,
  status text not null default 'dispatched' check(status in ('dispatched','completed','failed','unknown','resolved')),
  receipt jsonb not null default '{}',
  charged_microusd bigint not null check(charged_microusd >= 0),
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  unique(capability_id,operation_key)
);
-- Uncertain writes quarantine the account until an operator verifies the provider outcome.
-- A timeout or process exit must never make a second dispatch safe by itself.
create unique index hosted_connector_uncertain_write on public.hosted_connector_operations(connection_id)
  where is_write and status in ('dispatched','unknown');
create table public.hosted_connector_cursors (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.hosted_connector_accounts(id) on delete cascade,
  generation integer not null,
  tool text not null,
  request_hash text not null,
  value jsonb not null,
  expires_at timestamptz not null default (now()+interval '2 days')
);
create table public.hosted_connector_usage (
  bucket text primary key,
  calls bigint not null default 0,
  background_calls bigint not null default 0,
  microusd bigint not null default 0,
  requests bigint not null default 0
);
create table public.hosted_connector_cleanup (
  kind text not null check(kind in ('account','connection','session')),
  upstream_id text not null,
  auth_config text not null,
  connection_id uuid references public.hosted_connector_accounts(id) on delete set null,
  created_at timestamptz not null default now(),
  available_after timestamptz not null default now(),
  attempts integer not null default 0,
  primary key(kind,upstream_id)
);
do $$ declare t text; begin
  foreach t in array array['policy','users','accounts','attempts','capabilities','operations','cursors','usage','cleanup'] loop
    execute format('alter table public.%I enable row level security','hosted_connector_'||t);
    execute format('revoke all on public.%I from public, anon, authenticated','hosted_connector_'||t);
    execute format('grant all on public.%I to service_role','hosted_connector_'||t);
  end loop;
end $$;

create function public.hosted_connectors(operation text,args jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  principal uuid;
  p public.hosted_connector_policy%rowtype;
  c public.hosted_connector_accounts%rowtype;
  a public.hosted_connector_attempts%rowtype;
  k public.hosted_connector_capabilities%rowtype;
  r public.hosted_inference_runs%rowtype;
  q public.hosted_connector_operations%rowtype;
  u public.hosted_connector_users%rowtype;
  result jsonb;
  at_time timestamptz;
  day_key text;
  month_key text;
  user_key text;
  minute_key text;
  item record;
  bg boolean;
  request_units integer;
begin
  if operation='cleanup_delay' then
    update public.hosted_connector_cleanup set available_after=greatest(available_after,
      clock_timestamp()+least(300,greatest(60,(args->>'seconds')::integer))*interval '1 second')
      where kind=args->>'kind' and upstream_id=args->>'upstream_id';
    return '{}'::jsonb;
  end if;
  if operation='cleanup_enqueue' then
    insert into public.hosted_connector_cleanup(kind,upstream_id,auth_config) values(args->>'kind',args->>'upstream_id',args->>'auth_config') on conflict do nothing;
    return '{}'::jsonb;
  end if;
  if operation='cleanup_claim' then
    select * into p from public.hosted_connector_policy where singleton;
    minute_key:='minute:global:'||to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD-HH24-MI');
    insert into public.hosted_connector_usage(bucket) values(minute_key) on conflict do nothing;
    perform 1 from public.hosted_connector_usage where bucket=minute_key for update;
    if exists(select 1 from public.hosted_connector_usage where bucket=minute_key and requests+3>p.global_requests_per_minute) then
      return jsonb_build_object('claimed',false);
    end if;
    update public.hosted_connector_cleanup set available_after=clock_timestamp()+interval '1 minute',attempts=attempts+1
      where kind=args->>'kind' and upstream_id=args->>'upstream_id' and available_after<=clock_timestamp();
    if not found then return jsonb_build_object('claimed',false); end if;
    update public.hosted_connector_usage set requests=requests+3 where bucket=minute_key;
    return jsonb_build_object('claimed',true);
  end if;
  -- Maintenance is gateway-only. Rows remain queued until upstream deletion is confirmed.
  if operation='cleanup_list' then
    update public.hosted_connector_operations set status='unknown',settled_at=clock_timestamp()
      where status='dispatched' and created_at<clock_timestamp()-interval '2 minutes';
    update public.hosted_connector_attempts set status='expired' where status='pending' and expires_at<=clock_timestamp();
    update public.hosted_connector_accounts account set status=case when upstream_id is not null then 'active'
      when exists(select 1 from public.hosted_connector_attempts attempt where attempt.connection_id=account.id
        and attempt.status in ('cancelled','failed','expired') and attempt.upstream_id is not null) then 'disconnect_pending' else 'disconnected' end
      where status='connecting' and not exists(select 1 from public.hosted_connector_attempts attempt where attempt.connection_id=account.id and attempt.status='pending');
    insert into public.hosted_connector_cleanup(kind,upstream_id,connection_id,auth_config)
      select 'connection',attempt.upstream_id,attempt.connection_id,attempt.auth_config from public.hosted_connector_attempts attempt
      where attempt.status in ('cancelled','failed','expired') and attempt.upstream_id is not null on conflict do nothing;
    update public.hosted_connector_capabilities cap set closed=true from public.hosted_inference_runs run
      where run.id=cap.run_id and (run.phase in ('expired','completed') or run.lease_expires_at<=clock_timestamp());
    insert into public.hosted_connector_cleanup(kind,upstream_id,auth_config)
      select 'session',session_id,auth_config from public.hosted_connector_capabilities where closed and session_id is not null and not session_deleted on conflict do nothing;
    delete from public.hosted_connector_cursors where expires_at<=clock_timestamp();
    delete from public.hosted_connector_attempts where status<>'pending' and created_at<clock_timestamp()-interval '90 days';
    delete from public.hosted_connector_capabilities cap where closed and session_deleted and created_at<clock_timestamp()-interval '90 days'
      and not exists(select 1 from public.hosted_connector_operations op where op.capability_id=cap.id and op.status in ('dispatched','unknown'));
    return jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(x)) from
      (select kind,upstream_id,connection_id,auth_config from public.hosted_connector_cleanup where available_after<=clock_timestamp() order by created_at limit 30) x),'[]'::jsonb));
  end if;
  if operation='cleanup_done' then
    delete from public.hosted_connector_cleanup where kind=args->>'kind' and upstream_id=args->>'upstream_id';
    if args->>'kind' in ('account','connection') then
      update public.hosted_connector_attempts set upstream_id=null where upstream_id=args->>'upstream_id' and status<>'completed';
      update public.hosted_connector_accounts set upstream_id=null
        where upstream_id=args->>'upstream_id' and status in ('disconnect_pending','revocation_pending');
      update public.hosted_connector_accounts account set status='disconnected'
        where account.status in ('disconnect_pending','revocation_pending') and account.upstream_id is null
        and not exists(select 1 from public.hosted_connector_cleanup job where job.connection_id=account.id)
        and not exists(select 1 from public.hosted_connector_attempts attempt where attempt.connection_id=account.id
          and attempt.status in ('cancelled','failed','expired') and attempt.upstream_id is not null);
    else update public.hosted_connector_capabilities set session_deleted=true where session_id=args->>'upstream_id' and closed;
    end if;
    return '{}'::jsonb;
  end if;
  if operation='callback' or operation='complete_attempt' and args ? 'state_hash' then
    select * into a from public.hosted_connector_attempts where state_hash=args->>'state_hash';
    if not found then return jsonb_build_object('error','invalid_attempt','status',404); end if;
    select principal_id into principal from public.hosted_connector_accounts where id=a.connection_id;
  elsif args ? 'principal_id' then principal := (args->>'principal_id')::uuid;
  elsif args ? 'run_token_hash' then
    select * into r from public.hosted_inference_runs where token_hash=args->>'run_token_hash'; principal:=r.principal_id;
  else
    select * into k from public.hosted_connector_capabilities where token_hash=args->>'token_hash';
    select * into r from public.hosted_inference_runs where id=k.run_id; principal:=r.principal_id;
  end if;
  if principal is null or not exists(select 1 from auth.users where id=principal) then
    return jsonb_build_object('error','authentication_required','status',401);
  end if;
  -- Same principal lock as inference: disconnect/reconnect and run admission cannot race a
  -- capability reservation. Aggregate connector rows are always locked in lexical order.
  perform pg_advisory_xact_lock(hashtextextended(principal::text,29100001));
  at_time:=clock_timestamp();
  select * into p from public.hosted_connector_policy where singleton;
  if exists(select 1 from public.hosted_inference_principals where principal_id=principal and disabled)
    and operation not in ('settle','close','disconnect','cancel') then
    return jsonb_build_object('error','authentication_required','status',403);
  end if;
  insert into public.hosted_connector_users(principal_id) values(principal) on conflict do nothing;
  select * into u from public.hosted_connector_users where principal_id=principal;
  if operation='prepare' then
    select * into r from public.hosted_inference_runs where id=(args->>'run_id')::uuid and principal_id=principal;
    if not found then return jsonb_build_object('error','run_not_found','status',404); end if;
  end if;
  if args ? 'connection_id' then
    select * into c from public.hosted_connector_accounts where id=(args->>'connection_id')::uuid and principal_id=principal for update;
    if not found then return jsonb_build_object('error','connection_not_found','status',404); end if;
  end if;
  if args ? 'attempt_id' or operation='callback' then
    select x.* into a from public.hosted_connector_attempts x join public.hosted_connector_accounts y on y.id=x.connection_id
      where y.principal_id=principal and (x.id=(args->>'attempt_id')::uuid or operation='callback' and x.state_hash=args->>'state_hash') for update of x;
    if not found then return jsonb_build_object('error','invalid_attempt','status',404); end if;
    select * into c from public.hosted_connector_accounts where id=a.connection_id for update;
  end if;
  if k.id is not null then
    select * into k from public.hosted_connector_capabilities where id=k.id for update;
    select * into c from public.hosted_connector_accounts where id=k.connection_id for update;
  end if;
  if operation='uncertain_actions' then
    return jsonb_build_object('actions',coalesce((select jsonb_agg(jsonb_build_object('id',id,'tool',tool,'created_at',created_at))
      from public.hosted_connector_operations where connection_id=c.id and is_write and status in ('dispatched','unknown')),'[]'::jsonb));
  end if;
  if operation='resolve_action' then
    select * into q from public.hosted_connector_operations where id=(args->>'operation_id')::uuid and connection_id=c.id and is_write for update;
    if not found then return jsonb_build_object('error','operation_not_found','status',404); end if;
    if q.status not in ('dispatched','unknown') then return '{}'::jsonb; end if;
    select run.* into r from public.hosted_inference_runs run join public.hosted_connector_capabilities cap on cap.run_id=run.id where cap.id=q.capability_id;
    if q.created_at>at_time-interval '2 minutes' or r.phase in ('running','waiting_for_user') and r.lease_expires_at>at_time then
      return jsonb_build_object('error','resolution_not_ready','status',409);
    end if;
    if args->>'outcome' not in ('reported_completed','allow_retry') then return jsonb_build_object('error','invalid_request','status',400); end if;
    -- Authenticated account-owner review is distinct from a native completion receipt.
    -- It never replays an action, refunds uncertain cost, or revives the old capabilities.
    update public.hosted_connector_operations set status='resolved',settled_at=at_time,
      receipt=jsonb_build_object('outcome','user_'||(args->>'outcome')) where id=q.id;
    update public.hosted_connector_capabilities set closed=true where connection_id=c.id;
    return '{}'::jsonb;
  end if;
  if operation='settle' then
    select * into q from public.hosted_connector_operations where id=(args->>'operation_id')::uuid and capability_id=k.id for update;
    if not found then return jsonb_build_object('error','operation_not_found','status',404); end if;
    if q.status='dispatched' then
      if args->>'status' not in ('completed','failed','unknown') or pg_column_size(args->'receipt')>4096 then
        return jsonb_build_object('error','invalid_request','status',400);
      end if;
      update public.hosted_connector_operations set status=args->>'status',receipt=coalesce(args->'receipt','{}'),settled_at=at_time where id=q.id;
    end if;
    return '{}'::jsonb;
  end if;
  if operation in ('close','disconnect','cancel') then
    if operation='close' then update public.hosted_connector_capabilities set closed=true where id=k.id;
    else
      if operation='cancel' then
        if a.status='completed' then return jsonb_build_object('status','completed'); end if;
        update public.hosted_connector_attempts set status='cancelled' where id=a.id and status='pending';
        if a.upstream_id is not null then insert into public.hosted_connector_cleanup(kind,upstream_id,connection_id,auth_config)
          values('connection',a.upstream_id,c.id,a.auth_config) on conflict do nothing; end if;
        -- A failed reconnect leaves the old connection available under its new generation.
        update public.hosted_connector_accounts set status=case when upstream_id is not null then 'active'
          when a.upstream_id is not null then 'disconnect_pending' else 'disconnected' end
          where id=c.id and generation=a.generation and status not in ('disconnected','disconnect_pending','revocation_pending');
      else
        -- Once cleanup starts its chosen scope cannot change under an in-flight deletion.
        if c.status in ('disconnect_pending','revocation_pending') then return jsonb_build_object('status','closed'); end if;
        update public.hosted_connector_accounts set generation=generation+1,
          status=case when upstream_id is not null and coalesce((args->>'revoke_provider')::boolean,false) then 'revocation_pending'
            when upstream_id is not null or exists(select 1 from public.hosted_connector_attempts attempt where attempt.connection_id=c.id
              and attempt.status<>'completed' and attempt.upstream_id is not null) then 'disconnect_pending' else 'disconnected' end where id=c.id;
        update public.hosted_connector_attempts set status='cancelled' where connection_id=c.id and status='pending';
        insert into public.hosted_connector_cleanup(kind,upstream_id,connection_id,auth_config)
          select 'connection',upstream_id,connection_id,auth_config from public.hosted_connector_attempts
          where connection_id=c.id and status in ('cancelled','failed','expired') and upstream_id is not null on conflict do nothing;
        if c.upstream_id is not null then insert into public.hosted_connector_cleanup(kind,upstream_id,connection_id,auth_config)
          values(case when coalesce((args->>'revoke_provider')::boolean,false) then 'account' else 'connection' end,c.upstream_id,c.id,c.auth_config) on conflict do nothing; end if;
      end if;
      update public.hosted_connector_capabilities set closed=true where connection_id=c.id and (operation='disconnect' or generation=a.generation);
    end if;
    return jsonb_build_object('status','closed');
  end if;
  if operation='list' then return jsonb_build_object('revision',u.revision,'connections',coalesce((select jsonb_agg(jsonb_build_object(
    'id',id,'service',service,'generation',generation,'label',label,'status',status)) from public.hosted_connector_accounts
    where principal_id=principal),'[]'::jsonb)); end if;
  if not p.enabled then return jsonb_build_object('error','connectors_disabled','status',503); end if;
  if operation='check_run' then
    if r.id is null then return jsonb_build_object('error','authentication_required','status',401); end if;
    perform public.hosted_inference_clock(r.id,at_time);
    select * into r from public.hosted_inference_runs where id=r.id;
    if r.phase not in ('running','waiting_for_user') then return jsonb_build_object('error','run_expired','status',409); end if;
    if exists(select 1 from jsonb_array_elements_text(args->'connections') wanted where not exists(
      select 1 from public.hosted_connector_capabilities cap join public.hosted_connector_accounts account on account.id=cap.connection_id
      where cap.run_id=r.id and cap.connection_id=wanted.value::uuid and not cap.closed and cap.generation=account.generation and account.status='active')) then
      return jsonb_build_object('error','connection_changed','status',409);
    end if;
    return '{}'::jsonb;
  end if;
  minute_key:=to_char(at_time at time zone 'UTC','YYYY-MM-DD-HH24-MI');
  if operation not in ('inspect','reserve','cursor_get','cursor_put','bind_attempt','complete_attempt','bind_session') then
    -- Preparation makes up to three upstream requests: account, session, tool inventory.
    -- Reserve the full metadata cost even if an earlier request fails.
    request_units:=case when operation='prepare' then 3 else 1 end;
    insert into public.hosted_connector_usage(bucket) values('minute:global:'||minute_key),('minute:'||principal||':'||minute_key) on conflict do nothing;
    perform 1 from public.hosted_connector_usage where bucket in ('minute:global:'||minute_key,'minute:'||principal||':'||minute_key) order by bucket for update;
    if exists(select 1 from public.hosted_connector_usage where bucket='minute:'||principal||':'||minute_key and requests+request_units>p.requests_per_minute)
      or exists(select 1 from public.hosted_connector_usage where bucket='minute:global:'||minute_key and requests+request_units>p.global_requests_per_minute) then
      return jsonb_build_object('error','connector_rate_limited','status',429);
    end if;
    update public.hosted_connector_usage set requests=requests+request_units where bucket in ('minute:global:'||minute_key,'minute:'||principal||':'||minute_key);
  end if;
  if operation='begin' then
    if c.id is null then
      if (select count(*) from public.hosted_connector_accounts where principal_id=principal)>=p.connections_per_user then
        return jsonb_build_object('error','connection_limit','status',429); end if;
      insert into public.hosted_connector_accounts(principal_id,service,auth_config,label)
        values(principal,args->>'service',args->>'auth_config',args->>'label') returning * into c;
    else
      if c.status in ('disconnect_pending','revocation_pending') then return jsonb_build_object('error','revocation_pending','status',409); end if;
      update public.hosted_connector_attempts set status='cancelled' where connection_id=c.id and status='pending';
      update public.hosted_connector_capabilities set closed=true where connection_id=c.id;
      update public.hosted_connector_accounts set generation=generation+1,status='connecting' where id=c.id returning * into c;
    end if;
    insert into public.hosted_connector_attempts(id,connection_id,generation,auth_config,state_hash,expires_at)
      values((args->>'id')::uuid,c.id,c.generation,args->>'auth_config',args->>'state_hash',at_time+interval '10 minutes') returning * into a;
    return jsonb_build_object('attempt_id',a.id,'connection_id',c.id,'generation',c.generation,'composio_user',u.composio_user,
      'service',c.service,'auth_config',a.auth_config,'expires_at',a.expires_at);
  end if;
  if operation in ('attempt','callback','bind_attempt','complete_attempt') then
    if a.status='pending' and a.expires_at<=at_time then
      update public.hosted_connector_attempts set status='expired' where id=a.id; a.status:='expired';
    end if;
    if operation='bind_attempt' then
      -- Bind even a cancelled attempt so its newly created upstream account can be reaped.
      update public.hosted_connector_attempts set upstream_id=args->>'upstream_id' where id=a.id and upstream_id is null;
      if a.status<>'pending' then
        insert into public.hosted_connector_cleanup(kind,upstream_id,connection_id,auth_config)
          values('connection',args->>'upstream_id',c.id,a.auth_config) on conflict do nothing;
        update public.hosted_connector_accounts set status='disconnect_pending' where id=c.id and status='disconnected';
      end if;
    elsif operation='complete_attempt' and a.status='pending' and a.generation=c.generation then
      if c.upstream_id is not null and c.upstream_id<>a.upstream_id then
        insert into public.hosted_connector_cleanup(kind,upstream_id,auth_config) values('connection',c.upstream_id,c.auth_config) on conflict do nothing;
      end if;
      update public.hosted_connector_accounts set upstream_id=a.upstream_id,auth_config=a.auth_config,status='active' where id=c.id;
      update public.hosted_connector_attempts set status='completed' where id=a.id; a.status:='completed';
    end if;
    return jsonb_build_object('attempt_id',a.id,'connection_id',c.id,'generation',c.generation,'status',a.status,
      'composio_user',u.composio_user,'upstream_id',a.upstream_id,'auth_config',a.auth_config,'service',c.service);
  end if;
  if r.id is not null then
    result:=public.hosted_inference('inspect',jsonb_build_object('token_hash',r.token_hash));
    if result ? 'error' then return result; end if;
    select * into r from public.hosted_inference_runs where id=r.id;
  else return jsonb_build_object('error','authentication_required','status',401);
  end if;
  if c.status<>'active' or c.upstream_id is null then return jsonb_build_object('error','connection_required','status',409); end if;
  if operation='prepare' then
    if c.generation<>(args->>'generation')::integer then return jsonb_build_object('error','connection_changed','status',409); end if;
    if args->>'mode'='action' and r.purpose<>'sidekick' then return jsonb_build_object('error','tool_not_allowed','status',403); end if;
    if (select count(*) from public.hosted_connector_capabilities where run_id=r.id and not closed)>=20 then
      return jsonb_build_object('error','capability_limit','status',429); end if;
    insert into public.hosted_connector_capabilities(id,token_hash,run_id,connection_id,generation,mode,auth_config)
      values((args->>'id')::uuid,args->>'capability_hash',r.id,c.id,c.generation,args->>'mode',c.auth_config) returning * into k;
  else
    if k.id is null or k.closed or k.generation<>c.generation then return jsonb_build_object('error','connection_changed','status',409); end if;
  end if;
  if operation='bind_session' then
    update public.hosted_connector_capabilities set session_id=args->>'session_id' where id=k.id and session_id is null;
  end if;
  result:=jsonb_build_object('capability_id',k.id,'connection_id',c.id,'generation',c.generation,'mode',k.mode,
    'composio_user',u.composio_user,'upstream_id',c.upstream_id,'auth_config',c.auth_config,'service',c.service,
    'session_id',k.session_id,'run_id',r.id,'server_time',at_time,'lease_expires_at',r.lease_expires_at);
  if operation in ('prepare','bind_session','inspect','admit') then return result; end if;
  if operation='cursor_get' then
    return coalesce((select jsonb_build_object('value',value) from public.hosted_connector_cursors where
      id=(args->>'cursor_id')::uuid and connection_id=c.id and generation=c.generation and tool=args->>'tool'
      and request_hash=args->>'request_hash' and expires_at>at_time),jsonb_build_object('error','cursor_expired','status',409));
  end if;
  if operation='cursor_put' then
    if pg_column_size(args->'value')>12000 then return jsonb_build_object('error','invalid_cursor','status',502); end if;
    select id into principal from public.hosted_connector_cursors where connection_id=c.id and generation=c.generation
      and tool=args->>'tool' and request_hash=args->>'request_hash' and value=args->'value' and expires_at>at_time limit 1;
    if found then return jsonb_build_object('cursor',principal); end if;
    insert into public.hosted_connector_cursors(connection_id,generation,tool,request_hash,value)
      values(c.id,c.generation,args->>'tool',args->>'request_hash',args->'value') returning id into principal;
    return jsonb_build_object('cursor',principal);
  end if;
  if operation<>'reserve' then return jsonb_build_object('error','invalid_operation','status',400); end if;
  if (args->>'is_write')::boolean and (k.mode<>'action' or r.purpose<>'sidekick') then
    return jsonb_build_object('error','tool_not_allowed','status',403); end if;
  select * into q from public.hosted_connector_operations where capability_id=k.id and operation_key=(args->>'operation_key')::uuid;
  if found then
    if q.request_hash<>args->>'request_hash' then return jsonb_build_object('error','idempotency_conflict','status',409); end if;
    return jsonb_build_object('replay',true,'status',q.status,'receipt',q.receipt,'operation_id',q.id);
  end if;
  if (args->>'is_write')::boolean and exists(select 1 from public.hosted_connector_operations where connection_id=c.id and is_write and status in ('dispatched','unknown')) then
    return jsonb_build_object('error','write_outcome_unknown','status',409); end if;
  -- Different MCP request IDs or a newly prepared capability in the same foreground task
  -- cannot repeat an already confirmed identical mutation.
  if (args->>'is_write')::boolean then
    select op.* into q from public.hosted_connector_operations op join public.hosted_connector_capabilities cap on cap.id=op.capability_id
      where cap.run_id=r.id and op.connection_id=c.id and op.generation=c.generation
        and op.is_write and op.request_hash=args->>'request_hash' and op.status='completed' limit 1;
    if found then return jsonb_build_object('replay',true,'status',q.status,'receipt',q.receipt,'operation_id',q.id); end if;
  end if;
  if (select count(*) from public.hosted_connector_operations op join public.hosted_connector_capabilities x on x.id=op.capability_id
      where x.run_id=r.id and op.status='dispatched' and op.created_at>at_time-interval '2 minutes')>=2 then
    return jsonb_build_object('error','connector_busy','status',409); end if;
  day_key:='day:'||to_char(at_time at time zone 'UTC','YYYY-MM-DD');
  month_key:='month:'||to_char(at_time at time zone 'UTC','YYYY-MM'); user_key:=day_key||':'||principal;
  insert into public.hosted_connector_usage(bucket) values(day_key),(month_key),(user_key) on conflict do nothing;
  perform 1 from public.hosted_connector_usage where bucket in (day_key,month_key,user_key) order by bucket for update;
  bg:=r.purpose<>'sidekick';
  if not p.pricing_verified or exists(select 1 from public.hosted_connector_usage where bucket=user_key and
      (calls>=p.user_daily_calls or bg and background_calls>=p.background_daily_calls or microusd+p.call_microusd>p.user_daily_microusd)) then
    return jsonb_build_object('error','connector_usage_limit','status',429); end if;
  if exists(select 1 from public.hosted_connector_usage where bucket=day_key and calls>=p.global_daily_calls)
      or exists(select 1 from public.hosted_connector_usage where bucket=month_key and (calls>=p.global_monthly_calls or microusd+p.call_microusd>p.global_monthly_microusd)) then
    return jsonb_build_object('error','connector_service_budget','status',503); end if;
  insert into public.hosted_connector_operations(capability_id,connection_id,generation,operation_key,request_hash,tool,is_write,charged_microusd)
    values(k.id,c.id,c.generation,(args->>'operation_key')::uuid,args->>'request_hash',args->>'tool',(args->>'is_write')::boolean,p.call_microusd) returning * into q;
  update public.hosted_connector_usage set calls=calls+1,background_calls=background_calls+case when bg then 1 else 0 end,
    microusd=microusd+p.call_microusd where bucket in (day_key,month_key,user_key);
  return result||jsonb_build_object('operation_id',q.id,'status','dispatched','replay',false);
end;
$$;
revoke all on function public.hosted_connectors(text,jsonb) from public,anon,authenticated;
grant execute on function public.hosted_connectors(text,jsonb) to service_role;

-- A user-wait pause cannot stop the clock while a cloud tool is still executing. Preserve
-- the existing inference RPC, lock order, response contract and settlement behavior.
alter function public.hosted_inference(text,jsonb) rename to hosted_inference_core;
revoke all on function public.hosted_inference_core(text,jsonb) from public,anon,authenticated,service_role;
create function public.hosted_inference(operation text,args jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare run public.hosted_inference_runs%rowtype;
begin
  if operation='pause' then
    select * into run from public.hosted_inference_runs where token_hash=args->>'token_hash';
    if found then
      perform pg_advisory_xact_lock(hashtextextended(run.principal_id::text,29100001));
      if exists(select 1 from public.hosted_connector_operations op join public.hosted_connector_capabilities cap on cap.id=op.capability_id
        where cap.run_id=run.id and op.status='dispatched') then
        return jsonb_build_object('error','run_busy','status',409);
      end if;
    end if;
  end if;
  return public.hosted_inference_core(operation,args);
end;
$$;
revoke all on function public.hosted_inference(text,jsonb) from public,anon,authenticated;
grant execute on function public.hosted_inference(text,jsonb) to service_role;

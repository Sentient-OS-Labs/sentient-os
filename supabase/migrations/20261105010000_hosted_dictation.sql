-- Token issuance only; no speech, transcripts or provider credentials are stored here.
-- Installed disabled. Operator-owned quotas plus provider account limits govern activation.
create table public.hosted_dictation_policy (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  user_daily_tokens integer not null default 0 check (user_daily_tokens between 0 and 10000),
  global_daily_tokens integer not null default 0 check (global_daily_tokens >= 0),
  global_monthly_tokens integer not null default 0 check (global_monthly_tokens >= 0),
  user_minute_tokens integer not null default 6 check (user_minute_tokens between 1 and 60)
);
insert into public.hosted_dictation_policy(singleton) values (true);
create table public.hosted_dictation_issuance (
  id bigint generated always as identity primary key,
  principal_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index hosted_dictation_issued_at on public.hosted_dictation_issuance(created_at);
create index hosted_dictation_user_issued_at on public.hosted_dictation_issuance(principal_id, created_at);
alter table public.hosted_dictation_policy enable row level security;
alter table public.hosted_dictation_issuance enable row level security;
revoke all on public.hosted_dictation_policy, public.hosted_dictation_issuance from public, anon, authenticated;

create function public.hosted_dictation(operation text, args jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p public.hosted_dictation_policy%rowtype;
  principal uuid;
  t timestamptz := now();
  day_start timestamptz := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
  month_start timestamptz := date_trunc('month', now() at time zone 'UTC') at time zone 'UTC';
begin
  if operation <> 'issue' then return jsonb_build_object('error','invalid_request','status',400); end if;
  principal := (args->>'principal_id')::uuid;
  if not exists(select 1 from auth.users where id=principal) then
    return jsonb_build_object('error','authentication_required','status',401);
  end if;
  -- Serialize admission across users so concurrent requests cannot overrun global limits.
  select * into p from public.hosted_dictation_policy where singleton for update;
  if not found or not p.enabled then return jsonb_build_object('error','dictation_not_configured','status',503); end if;
  if (select count(*) from public.hosted_dictation_issuance where created_at >= month_start) >= p.global_monthly_tokens
    or (select count(*) from public.hosted_dictation_issuance where created_at >= day_start) >= p.global_daily_tokens then
    return jsonb_build_object('error','dictation_service_limit','status',429);
  end if;
  if (select count(*) from public.hosted_dictation_issuance where principal_id=principal and created_at >= day_start) >= p.user_daily_tokens
    or (select count(*) from public.hosted_dictation_issuance where principal_id=principal and created_at > t-interval '1 minute') >= p.user_minute_tokens then
    return jsonb_build_object('error','dictation_rate_limited','status',429);
  end if;
  delete from public.hosted_dictation_issuance where created_at < month_start;
  insert into public.hosted_dictation_issuance(principal_id) values (principal);
  return jsonb_build_object('accepted',true);
end;
$$;
revoke all on function public.hosted_dictation(text,jsonb) from public, anon, authenticated;
grant execute on function public.hosted_dictation(text,jsonb) to service_role;

-- The public relay carries only the caller's JWT and the project's publishable key.
-- This narrow entry point derives ownership from Supabase's verified JWT, never a client ID.
create function public.reserve_dictation_token() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare principal uuid := auth.uid();
begin
  if principal is null then return jsonb_build_object('error','authentication_required','status',401); end if;
  return public.hosted_dictation('issue', jsonb_build_object('principal_id', principal));
end;
$$;
revoke all on function public.reserve_dictation_token() from public, anon;
grant execute on function public.reserve_dictation_token() to authenticated;

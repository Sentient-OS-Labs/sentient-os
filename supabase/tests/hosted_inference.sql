-- Transactional hosted-ledger tests against real PostgreSQL functions. No external services.
-- Run via HostedInference/npm test or an isolated local Supabase database, never production.
begin;
create function pg_temp.check_true(value boolean, message text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'Hosted assertion: %',message; end if; end;
$$;
insert into auth.users(id) values('20000000-0000-4000-8000-000000000001'),('20000000-0000-4000-8000-000000000002');
update public.hosted_inference_policy set enabled=true,user_daily_microusd=10000,
    background_daily_microusd=2000,bootstrap_lifetime_microusd=3000,
    global_daily_microusd=15000,global_monthly_microusd=20000;
select pg_temp.check_true(not has_function_privilege('anon','public.hosted_inference(text,jsonb)','execute'),'anon cannot call accounting');
select pg_temp.check_true(not has_function_privilege('authenticated','public.hosted_inference(text,jsonb)','execute'),'clients cannot call accounting');
select pg_temp.check_true(has_function_privilege('service_role','public.hosted_inference(text,jsonb)','execute'),'gateway can call accounting');

do $$
declare
    principal uuid:='20000000-0000-4000-8000-000000000001';
    run jsonb;
    other jsonb;
    request jsonb;
    actual jsonb;
    run_id uuid;
    total bigint;
    today date:=(clock_timestamp() at time zone 'UTC')::date;
begin
    run:=public.hosted_inference('create',jsonb_build_object('principal_id',principal,'purpose','sidekick','model','fixture','token_hash',repeat('a',64)));
    run_id:=(run->>'run_id')::uuid;
    perform pg_temp.check_true((run->>'remaining_seconds')::numeric=3600,'fresh allowance');
    other:=public.hosted_inference('create',jsonb_build_object('principal_id',principal,'purpose','sidekick','model','fixture','token_hash',repeat('b',64)));
    perform pg_temp.check_true(other->>'error'='run_busy','single foreground run');
    other:=public.hosted_inference('inspect',jsonb_build_object('token_hash',repeat('c',64)));
    perform pg_temp.check_true(other->>'error'='authentication_required','unknown token denied');
    other:=public.hosted_inference('pause',jsonb_build_object('token_hash',repeat('a',64)));
    perform pg_temp.check_true(other->>'phase'='waiting_for_user','pause transition');
    update public.hosted_inference_runs set last_accounted_at=clock_timestamp()-interval '1 hour' where id=run_id;
    other:=public.hosted_inference('heartbeat',jsonb_build_object('token_hash',repeat('a',64)));
    perform pg_temp.check_true((other->>'used_seconds')::numeric<1,'waiting does not charge an hour');
    other:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('a',64),'reserve_microusd',100));
    perform pg_temp.check_true(other->>'error'='run_paused','paused cannot infer');
    other:=public.hosted_inference('resume',jsonb_build_object('token_hash',repeat('a',64)));
    perform pg_temp.check_true(other->>'phase'='running' and other->>'model'='fixture','resume pins model');
    request:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('a',64),'reserve_microusd',1000,
        'idempotency_key','step-1','request_hash',repeat('1',64)));
    perform pg_temp.check_true(request ? 'request_id','reserve succeeds');
    other:=public.hosted_inference('pause',jsonb_build_object('token_hash',repeat('a',64)));
    perform pg_temp.check_true(other->>'error'='run_busy','cannot pause in-flight inference');
    other:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('a',64),'reserve_microusd',1000,
        'idempotency_key','step-1','request_hash',repeat('1',64)));
    perform pg_temp.check_true(other->>'error'='request_already_dispatched','retry never dispatches twice');
    other:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('a',64),'reserve_microusd',1000,
        'idempotency_key','step-1','request_hash',repeat('2',64)));
    perform pg_temp.check_true(other->>'error'='idempotency_conflict','changed retry payload denied');
    select charged_microusd into total from public.hosted_inference_daily where principal_id=principal and day=today;
    perform pg_temp.check_true(total=1000,'retries cannot double charge');
    actual:=public.hosted_inference('settle',jsonb_build_object('token_hash',repeat('a',64),'request_id',request->>'request_id',
        'actual_microusd',100,'status','completed','usage',jsonb_build_object('input_tokens',1,'output_tokens',1)));
    select charged_microusd into total from public.hosted_inference_daily where principal_id=principal and day=today;
    perform pg_temp.check_true(total=100,'settle refunds unused reservation');
    actual:=public.hosted_inference('settle',jsonb_build_object('token_hash',repeat('a',64),'request_id',request->>'request_id',
        'actual_microusd',0,'status','completed','usage','{}'::jsonb));
    select charged_microusd into total from public.hosted_inference_daily where principal_id=principal and day=today;
    perform pg_temp.check_true(total=100,'repeated settle cannot refund twice');
    other:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('a',64),'reserve_microusd',10000,
        'idempotency_key','too-much','request_hash',repeat('2',64)));
    perform pg_temp.check_true(other->>'error'='usage_limit_reached','aggregate budget reserves before upstream');
    request:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('a',64),'reserve_microusd',1000,
        'idempotency_key','step-2','request_hash',repeat('2',64)));
    actual:=public.hosted_inference('settle',jsonb_build_object('token_hash',repeat('a',64),'request_id',request->>'request_id',
        'actual_microusd',null,'status','unknown','usage','{}'::jsonb));
    select charged_microusd into total from public.hosted_inference_daily where principal_id=principal and day=today;
    perform pg_temp.check_true(total=1100,'unknown outcome conserves maximum reservation');
    update public.hosted_inference_daily set active_ms=3599900 where principal_id=principal and day=today;
    update public.hosted_inference_runs set last_accounted_at=clock_timestamp()-interval '1 second',lease_expires_at=clock_timestamp()+interval '20 seconds' where id=run_id;
    other:=public.hosted_inference('heartbeat',jsonb_build_object('token_hash',repeat('a',64)));
    perform pg_temp.check_true(other->>'error'='daily_time_exhausted','exact hour stops renewal');
    select active_ms into total from public.hosted_inference_daily where principal_id=principal and day=today;
    perform pg_temp.check_true(total=3600000,'clock caps at exactly one hour');

    -- Alternate purpose cannot escape shared dollars or its narrower background allocation.
    run:=public.hosted_inference('create',jsonb_build_object('principal_id',principal,'purpose','knowledge_update','model','fixture','token_hash',repeat('d',64)));
    other:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('d',64),'reserve_microusd',2001,
        'idempotency_key','background','request_hash',repeat('3',64)));
    perform pg_temp.check_true(other->>'error'='usage_limit_reached','background bounded separately');
    perform public.hosted_inference('finish',jsonb_build_object('token_hash',repeat('d',64)));
    run:=public.hosted_inference('create',jsonb_build_object('principal_id',principal,'purpose','knowledge_bootstrap','model','fixture','token_hash',repeat('e',64)));
    other:=public.hosted_inference('reserve',jsonb_build_object('token_hash',repeat('e',64),'reserve_microusd',3001,
        'idempotency_key','bootstrap','request_hash',repeat('4',64)));
    perform pg_temp.check_true(other->>'error'='usage_limit_reached','bootstrap has lifetime bound');

    -- UTC split does not depend on the database session's timezone.
    principal:='20000000-0000-4000-8000-000000000002';
    run:=public.hosted_inference('create',jsonb_build_object('principal_id',principal,'purpose','sidekick','model','fixture','token_hash',repeat('f',64)));
    run_id:=(run->>'run_id')::uuid;
    update public.hosted_inference_runs set last_accounted_at='2026-10-01 23:59:50+00',lease_expires_at='2026-10-02 00:00:30+00' where id=run_id;
    set local timezone='Pacific/Auckland';
    perform public.hosted_inference_clock(run_id,'2026-10-02 00:00:10+00');
    select active_ms into total from public.hosted_inference_daily where principal_id=principal and day='2026-10-01';
    perform pg_temp.check_true(total=10000,'old UTC day charge');
    select active_ms into total from public.hosted_inference_daily where principal_id=principal and day='2026-10-02';
    perform pg_temp.check_true(total=10000,'new UTC day charge');
    perform public.hosted_inference_clock(run_id,'2026-10-02 00:00:00+00');
    perform pg_temp.check_true((select last_accounted_at='2026-10-02 00:00:10+00' from public.hosted_inference_runs where id=run_id),
        'an older request timestamp cannot move accounting backwards');
    perform public.hosted_inference_clock(run_id,'2026-10-02 00:10:00+00');
    select active_ms into total from public.hosted_inference_daily where principal_id=principal and day='2026-10-02';
    perform pg_temp.check_true(total=30000,'crash charges only through lease');
    perform pg_temp.check_true((select phase='expired' from public.hosted_inference_runs where id=run_id),'stale lease expires');
end;
$$;

-- Frequent calls must not erase sub-millisecond active intervals. Use the real SQL
-- clock directly so this regression is deterministic and independent of test speed.
insert into auth.users(id) values('20000000-0000-4000-8000-000000000003');
do $$
declare
    principal uuid:='20000000-0000-4000-8000-000000000003';
    run jsonb;
    run_id uuid;
    origin timestamptz:='2026-10-03 12:00:00+00';
    total bigint;
begin
    run:=public.hosted_inference('create',jsonb_build_object('principal_id',principal,'purpose','sidekick','model','fixture','token_hash',repeat('9',64)));
    run_id:=(run->>'run_id')::uuid;
    update public.hosted_inference_runs set last_accounted_at=origin,lease_expires_at=origin+interval '10 seconds' where id=run_id;
    for step in 1..2000 loop
        perform public.hosted_inference_clock(run_id,origin+step*interval '500 microseconds');
    end loop;
    select active_ms into total from public.hosted_inference_daily where principal_id=principal and day='2026-10-03';
    perform pg_temp.check_true(total=2000,'each positive fractional millisecond rounds up rather than disappearing');
    update public.hosted_inference_daily set active_ms=3599999 where principal_id=principal and day='2026-10-03';
    perform public.hosted_inference_clock(run_id,origin+interval '1 second 500 microseconds');
    select active_ms into total from public.hosted_inference_daily where principal_id=principal and day='2026-10-03';
    perform pg_temp.check_true(total=3600000,'fractional accounting remains capped at exactly one hour');
    perform pg_temp.check_true((select phase='expired' from public.hosted_inference_runs where id=run_id),'fractional final interval expires the run');
end;
$$;
rollback;

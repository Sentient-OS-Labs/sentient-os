-- Apply through the normal release process before enabling report uploads in shipped clients.
-- Explicit uploads only. No conversation export, screenshots, account email or free text.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create table public.computer_use_support_reports (
    owner_id uuid not null references auth.users(id) on delete cascade,
    report_id uuid not null,
    received_at timestamptz not null default now(),
    report jsonb not null check (octet_length(report::text) <= 96000),
    primary key (owner_id, report_id)
);
create index computer_use_support_reports_received on public.computer_use_support_reports(received_at);
alter table public.computer_use_support_reports enable row level security;
alter table public.computer_use_support_reports force row level security;
revoke all on public.computer_use_support_reports from public, anon, authenticated;
grant select, insert, update, delete on public.computer_use_support_reports to service_role;

create function public.submit_computer_use_report(p_report jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    owner uuid := auth.uid();
    submitted_id uuid;
    previous jsonb;
    step jsonb;
    entry jsonb;
    pair record;
begin
    if owner is null or not exists (select 1 from auth.users where id = owner) then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if p_report is null or jsonb_typeof(p_report) <> 'object' or octet_length(p_report::text) > 96000
       or (p_report - array['schemaVersion','id','startedAt','finishedAt','source','environment','outcome',
            'permissions','steps','recentEvents','repairAttempted','repairVerified']) <> '{}'::jsonb
       or not (p_report ?& array['schemaVersion','id','startedAt','finishedAt','source','environment','outcome',
            'permissions','steps','recentEvents','repairAttempted','repairVerified'])
       or p_report->'schemaVersion' <> '1'::jsonb
       or coalesce(p_report->>'source', '') not in ('settings','agent')
       or coalesce(p_report->>'outcome', '') not in ('passed','repaired','permissionsNeeded','needsAttention','interrupted','cancelled','busy')
       or jsonb_typeof(p_report->'repairAttempted') <> 'boolean'
       or jsonb_typeof(p_report->'repairVerified') <> 'boolean' then
        raise exception 'Invalid report' using errcode = '22023';
    end if;
    submitted_id := (p_report->>'id')::uuid;
    if submitted_id is null or length(p_report->>'startedAt') > 40 or length(p_report->>'finishedAt') > 40
       or (p_report->>'startedAt')::timestamptz is null or (p_report->>'finishedAt')::timestamptz is null then
        raise exception 'Invalid report dates' using errcode = '22023';
    end if;
    if jsonb_typeof(p_report->'environment') <> 'object'
       or ((p_report->'environment') - array['appVersion','appBuild','binaryID','macOS','backend','helperVersion','helperBuild','cliVersion']) <> '{}'::jsonb
       or not (p_report->'environment' ?& array['appVersion','appBuild','binaryID','macOS','backend','helperVersion','helperBuild','cliVersion']) then
        raise exception 'Invalid environment' using errcode = '22023';
    end if;
    for pair in select key, value from jsonb_each_text(p_report->'environment') loop
        if pair.value is null or pair.value !~ '^[A-Za-z0-9._+-]{1,80}$' then
            raise exception 'Invalid environment value' using errcode = '22023';
        end if;
    end loop;
    if coalesce(p_report->'environment'->>'backend', '') not in ('chatgpt','claude','custom') then
        raise exception 'Invalid backend' using errcode = '22023';
    end if;
    if jsonb_typeof(p_report->'permissions') <> 'object'
       or ((p_report->'permissions') - array['automation','sentientScreenRecording','helperAccessibilityCached','helperScreenRecordingCached']) <> '{}'::jsonb then
        raise exception 'Invalid permissions' using errcode = '22023';
    end if;
    for pair in select key, value from jsonb_each_text(p_report->'permissions') loop
        if pair.value is null or pair.value not in ('granted','denied','notAsked','unavailable','unknown') then
            raise exception 'Invalid permission observation' using errcode = '22023';
        end if;
    end loop;
    if jsonb_typeof(p_report->'steps') <> 'array' or jsonb_array_length(p_report->'steps') > 8 then
        raise exception 'Invalid checks' using errcode = '22023';
    end if;
    for step in select value from jsonb_array_elements(p_report->'steps') loop
        if jsonb_typeof(step) <> 'object' or (step - array['check','status','detail','code','evidence']) <> '{}'::jsonb
           or not (step ?& array['check','status','evidence'])
           or coalesce(step->>'check', '') not in ('runtime','permissions','connection','accessibility','capture','click','textEntry','repair')
           or coalesce(step->>'status', '') not in ('running','passed','needsAttention','interrupted','skipped')
           or (step ? 'detail' and (step->>'detail' is null or step->>'detail' !~ '^[A-Za-z]{1,64}$'))
           or (step ? 'code' and (step->>'code' is null or step->>'code' !~ '^-?[0-9]{1,12}$'))
           or jsonb_typeof(step->'evidence') <> 'object'
           or ((step->'evidence') - array['runtime_error','native_kind','native_detail','failure_stage','native_code_present',
                'underlying_error_available','error_domain','native_error_code','error_code','rpc_error_code',
                'system_error_domain','system_error_code','exit_code','stderr_detail','stderr_evidence','stderr_native_code']) <> '{}'::jsonb then
            raise exception 'Invalid check evidence' using errcode = '22023';
        end if;
        for pair in select key, value from jsonb_each_text(step->'evidence') loop
            if pair.value is null or pair.value !~ '^[A-Za-z0-9_.-]{1,80}$' then
                raise exception 'Invalid evidence value' using errcode = '22023';
            end if;
        end loop;
    end loop;
    if jsonb_typeof(p_report->'recentEvents') <> 'array' or jsonb_array_length(p_report->'recentEvents') > 16 then
        raise exception 'Invalid recent events' using errcode = '22023';
    end if;
    for entry in select value from jsonb_array_elements(p_report->'recentEvents') loop
        if jsonb_typeof(entry) <> 'object' or (entry - array['at','event','fields']) <> '{}'::jsonb
           or not (entry ?& array['at','event','fields'])
           or coalesce(entry->>'event','') not in ('computer_use.capture','agent.tool_failed','agent.run_diagnostic')
           or jsonb_typeof(entry->'fields') <> 'object'
           or ((entry->'fields') - array['native_kind','native_detail','failure_stage','capture_source','capture_outcome',
                'backend','feature','tool_family','tool','reason','outcome','model_outcome','runtime_outcome','tool_recovery',
                'native_error_code','error_code','rpc_error_code','system_error_code','exit_code','duration_ms','capture_attempt',
                'tool_calls','tool_completed','tool_failed','tool_omitted','process_exit_code',
                'task_id','operation_id','root_operation_id','capture_id','system_error_domain']) <> '{}'::jsonb then
            raise exception 'Invalid recent evidence' using errcode = '22023';
        end if;
        if length(entry->>'at') > 40 or (entry->>'at')::timestamptz is null then
            raise exception 'Invalid event date' using errcode = '22023';
        end if;
        for pair in select key, value from jsonb_each_text(entry->'fields') loop
            if pair.value is null or pair.value !~ '^[A-Za-z0-9_.-]{1,80}$' then
                raise exception 'Invalid event value' using errcode = '22023';
            end if;
        end loop;
    end loop;
    -- One transaction per anonymous support identity makes quota and deduplication atomic.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner::text, 0));
    select r.report into previous from public.computer_use_support_reports r
      where r.owner_id = owner and r.report_id = submitted_id;
    if found then
        if previous <> p_report then raise exception 'Report already submitted' using errcode = '22023'; end if;
        return jsonb_build_object('id', submitted_id);
    end if;
    if (select count(*) from public.computer_use_support_reports where owner_id = owner
        and received_at > now() - interval '1 day') >= 10 then
        raise exception 'Try again later' using errcode = '54000';
    end if;
    insert into public.computer_use_support_reports(owner_id, report_id, report) values (owner, submitted_id, p_report);
    return jsonb_build_object('id', submitted_id);
end;
$$;
revoke all on function public.submit_computer_use_report(jsonb) from public, anon;
grant execute on function public.submit_computer_use_report(jsonb) to authenticated;
comment on table public.computer_use_support_reports is
    'Explicitly submitted content-free computer-use checks. Service-role support access only; never automatically uploaded.';
commit;

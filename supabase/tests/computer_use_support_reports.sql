-- Disposable schema and Auth fixtures; caller wraps everything in ROLLBACK.
do $$
declare
    sender uuid := gen_random_uuid();
    other_user uuid := gen_random_uuid();
    doc jsonb;
    reply jsonb;
    bad jsonb;
    n integer;
begin
    insert into auth.users(id) values(sender), (other_user);
    doc := jsonb_build_object('schemaVersion',1,'id',gen_random_uuid(),'startedAt',now(),'finishedAt',now(),
       'source','settings','outcome','passed','repairAttempted',false,'repairVerified',false,
       'environment',jsonb_build_object('appVersion','2.0.2','appBuild','13','binaryID',gen_random_uuid(),
          'macOS','27.2.0','backend','chatgpt','helperVersion','26.929.1001365','helperBuild',1001365,'cliVersion','0.160.0'),
       'recentEvents','[]'::jsonb,'permissions',jsonb_build_object('automation','granted'),
       'steps',jsonb_build_array(jsonb_build_object('check','capture','status','passed','evidence','{}'::jsonb)));
    set local role anon;
    begin
        perform public.submit_computer_use_report(doc);
        raise exception 'Unauthenticated upload accepted';
    exception when insufficient_privilege then null;
    end;
    reset role;
    perform set_config('request.jwt.claims', jsonb_build_object('sub',sender,'role','authenticated')::text, true);
    set local role authenticated;
    reply := public.submit_computer_use_report(doc);
    if reply->>'id' is distinct from doc->>'id' then raise exception 'Receipt did not match report'; end if;
    if public.submit_computer_use_report(doc) is distinct from reply then raise exception 'Retry was not idempotent'; end if;
    begin
        perform count(*) from public.computer_use_support_reports;
        raise exception 'Client could read support reports';
    exception when insufficient_privilege then null;
    end;
    begin
        delete from public.computer_use_support_reports;
        raise exception 'Client could delete support reports';
    exception when insufficient_privilege then null;
    end;
    begin
        perform public.submit_computer_use_report(doc || '{"outcome":"cancelled"}'::jsonb);
        raise exception 'Client could overwrite a submitted report';
    exception when invalid_parameter_value then null;
    end;
    for bad in select value from jsonb_array_elements(jsonb_build_array(
        doc || '{"promptHistory":["PRIVATE"]}'::jsonb,
        doc || '{"screenshots":["PRIVATE"]}'::jsonb,
        doc || '{"source":null}'::jsonb,
        jsonb_set(doc, '{environment}', (doc->'environment') || '{"email":"PRIVATE@example.com"}'::jsonb),
        jsonb_set(doc, '{permissions}', '{"automation":"PRIVATE"}'::jsonb),
        jsonb_set(doc, '{steps}', '[{"check":"capture","status":"needsAttention","evidence":{"raw_error":"PRIVATE"}}]'::jsonb)
    )) loop
        begin
            perform public.submit_computer_use_report(bad);
            raise exception 'Private or malformed fields were accepted';
        exception when invalid_parameter_value then null;
        end;
    end loop;
    for n in 2..10 loop
        perform public.submit_computer_use_report(doc || jsonb_build_object('id',gen_random_uuid()));
    end loop;
    begin
        perform public.submit_computer_use_report(doc || jsonb_build_object('id',gen_random_uuid()));
        raise exception 'Upload quota was not enforced';
    exception when program_limit_exceeded then null;
    end;
    if public.submit_computer_use_report(doc) is distinct from reply then raise exception 'Quota blocked an idempotent retry'; end if;
    reset role;
    if (select count(*) from public.computer_use_support_reports) <> 10 then raise exception 'Unexpected report count'; end if;
    perform set_config('request.jwt.claims', jsonb_build_object('sub',other_user,'role','authenticated')::text, true);
    set local role authenticated;
    perform public.submit_computer_use_report(doc);
    reset role;
    if (select count(*) from public.computer_use_support_reports) <> 11 then raise exception 'Owners were not isolated'; end if;
end;
$$;
select 'PASS: support report authentication, private-field rejection, idempotency, ownership and quotas' as result;

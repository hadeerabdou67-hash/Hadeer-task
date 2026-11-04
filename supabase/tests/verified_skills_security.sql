-- Verified Skills + Assessment Engine security smoke tests.
-- Run against a migrated Supabase project. All test data is rolled back.
begin;

do $tests$
declare
  v_demo_candidate uuid;
  v_sql_skill uuid;
  v_api_skill uuid;
  v_sql_assessment uuid;
  v_api_candidate_skill uuid;
  v_rls_disabled_count integer;
begin
  if has_table_privilege('authenticated','public.candidate_skills','INSERT') then
    raise exception 'FAIL: authenticated can directly insert candidate skills';
  end if;
  if has_table_privilege('authenticated','public.assessment_attempts','INSERT') then
    raise exception 'FAIL: authenticated can directly insert attempts';
  end if;
  if has_table_privilege('authenticated','public.assessment_answers','INSERT')
     or has_table_privilege('authenticated','public.assessment_answers','UPDATE') then
    raise exception 'FAIL: authenticated can directly write answers';
  end if;
  if has_table_privilege('authenticated','private.assessment_answer_keys','SELECT')
     or has_schema_privilege('authenticated','private','USAGE') then
    raise exception 'FAIL: private answer-key schema is exposed';
  end if;
  if has_function_privilege('authenticated','private.claim_candidate_skill(uuid)','EXECUTE')
     or has_function_privilege('authenticated','private.start_assessment_attempt(uuid,uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','private.save_assessment_answer(uuid,uuid,jsonb)','EXECUTE')
     or has_function_privilege('authenticated','private.submit_assessment_attempt(uuid)','EXECUTE') then
    raise exception 'FAIL: authenticated can directly execute a private workflow function';
  end if;
  if not has_function_privilege('authenticated','public.claim_candidate_skill(uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.start_assessment_attempt(uuid,uuid,text)','EXECUTE')
     or not has_function_privilege('authenticated','public.save_assessment_answer(uuid,uuid,jsonb)','EXECUTE')
     or not has_function_privilege('authenticated','public.submit_assessment_attempt(uuid)','EXECUTE') then
    raise exception 'FAIL: a guarded public RPC is not executable by authenticated users';
  end if;

  select count(*) into v_rls_disabled_count
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where (n.nspname='public' and c.relname in (
    'skill_categories','skills','candidate_profiles','candidate_skills','skill_evidence',
    'assessments','assessment_sections','assessment_questions','assessment_attempts',
    'assessment_answers','assessment_results','skill_verifications'
  ) or n.nspname='private' and c.relname='assessment_answer_keys')
    and c.relkind='r' and not c.relrowsecurity;
  if v_rls_disabled_count <> 0 then
    raise exception 'FAIL: one or more module tables have RLS disabled';
  end if;

  select id into v_demo_candidate from public.candidate_profiles
  where external_ref='demo-candidate-001' and is_demo;
  select id into v_sql_skill from public.skills where slug='sql-fundamentals';
  select id into v_api_skill from public.skills where slug='api-design';
  select id into v_sql_assessment from public.assessments
  where skill_id=v_sql_skill and is_published
  order by created_at limit 1;

  if v_demo_candidate is null or v_sql_skill is null or v_api_skill is null or v_sql_assessment is null then
    raise exception 'FAIL: required demo fixtures are missing';
  end if;

  insert into public.candidate_skills(candidate_id,skill_id,status)
  values(v_demo_candidate,v_api_skill,'claimed')
  on conflict(candidate_id,skill_id) do update set status='claimed'
  returning id into v_api_candidate_skill;

  begin
    insert into public.assessment_attempts(
      candidate_id,candidate_skill_id,assessment_id,attempt_number,status,expires_at
    ) values (
      v_demo_candidate,v_api_candidate_skill,v_sql_assessment,999,'in_progress',now()+interval '10 minutes'
    );
    raise exception 'FAIL: mismatched candidate skill/assessment relationship was accepted';
  exception when check_violation then
    null; -- expected: trigger rejects mismatched skill/assessment.
  end;
end;
$tests$;

rollback;

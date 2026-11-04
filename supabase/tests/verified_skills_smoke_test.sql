-- Run with a database-owner connection after applying migrations.
-- This is a read-only schema/security smoke test; it does not create test users or mutate data.
do $test$
begin
  if to_regclass('public.skills') is null
     or to_regclass('public.skill_categories') is null
     or to_regclass('public.candidate_skills') is null
     or to_regclass('public.skill_evidence') is null
     or to_regclass('public.assessments') is null
     or to_regclass('public.assessment_sections') is null
     or to_regclass('public.assessment_questions') is null
     or to_regclass('public.assessment_attempts') is null
     or to_regclass('public.assessment_answers') is null
     or to_regclass('public.assessment_results') is null
     or to_regclass('public.skill_verifications') is null
     or to_regclass('private.assessment_answer_keys') is null then
    raise exception 'One or more required Verified Skills tables are missing';
  end if;

  if exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and not c.relrowsecurity
      and c.relname in ('skills','skill_categories','candidate_profiles','candidate_skills',
        'skill_evidence','assessments','assessment_sections','assessment_questions',
        'assessment_attempts','assessment_answers','assessment_results','skill_verifications')
  ) then
    raise exception 'RLS is not enabled on every exposed module table';
  end if;

  if has_table_privilege('authenticated','private.assessment_answer_keys','select')
     or has_schema_privilege('authenticated','private','usage') then
    raise exception 'Authenticated role has access to private answer keys/schema';
  end if;

  if has_table_privilege('authenticated','public.assessment_attempts','insert')
     or has_table_privilege('authenticated','public.assessment_attempts','update')
     or has_table_privilege('authenticated','public.assessment_results','insert')
     or has_table_privilege('authenticated','public.skill_verifications','insert')
     or has_table_privilege('authenticated','public.skill_verifications','update') then
    raise exception 'Authenticated role can directly mutate assessment lifecycle records';
  end if;

  if has_function_privilege('authenticated','private.start_assessment_attempt(uuid,uuid,text)','execute')
     or has_function_privilege('authenticated','private.submit_assessment_attempt(uuid)','execute')
     or not has_function_privilege('authenticated','public.start_assessment_attempt(uuid,uuid,text)','execute')
     or not has_function_privilege('authenticated','public.submit_assessment_attempt(uuid)','execute') then
    raise exception 'Assessment RPC execution grants are incorrect';
  end if;

  if not exists (select 1 from pg_constraint where conname='attempts_candidate_skill_owner_fk' and convalidated) then
    raise exception 'Candidate/attempt ownership composite FK is missing or unvalidated';
  end if;

  if not exists (select 1 from pg_trigger where tgname='trg_guard_candidate_skill_status' and not tgisinternal)
     or not exists (select 1 from pg_trigger where tgname='trg_validate_assessment_answer' and not tgisinternal) then
    raise exception 'Assessment hardening triggers are missing';
  end if;

  if not exists (select 1 from public.candidate_profiles where external_ref='demo-candidate-001' and is_demo)
     or not exists (select 1 from public.skills where slug='sql-fundamentals')
     or not exists (select 1 from public.assessments where title='SQL Fundamentals — Demo Assessment' and is_published) then
    raise exception 'Required demo fixtures are missing';
  end if;
end;
$test$;

select 'Verified Skills schema/security smoke test passed' as test_result;

-- Transactional end-to-end workflow test for the Verified Skills module.
-- Uses a temporary Auth row and rolls every change back. Run with a database-owner session.
begin;

insert into auth.users(
  id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_anonymous,is_sso_user
) values (
  'f8f8a8b1-7f40-4d13-9b9e-9d4ef9a10a11'::uuid,
  'authenticated','authenticated','verified-skills-ci@example.invalid','',
  now(),'{"provider":"email","providers":["email"]}'::jsonb,
  '{"display_name":"Temporary CI Candidate"}'::jsonb,now(),now(),false,false
);

set local role authenticated;
select set_config('request.jwt.claim.sub','f8f8a8b1-7f40-4d13-9b9e-9d4ef9a10a11',true);

do $e2e$
declare
  v_candidate uuid;
  v_skill uuid;
  v_candidate_skill uuid;
  v_assessment uuid;
  v_attempt jsonb;
  v_attempt_id uuid;
  v_question uuid;
  v_result jsonb;
  v_badge_count integer;
begin
  if auth.uid() <> 'f8f8a8b1-7f40-4d13-9b9e-9d4ef9a10a11'::uuid then
    raise exception 'JWT subject simulation failed';
  end if;

  v_candidate := public.ensure_candidate_profile();
  select id into v_skill from public.skills where slug='sql-fundamentals';
  v_candidate_skill := (public.claim_candidate_skill(v_skill)->>'id')::uuid;

  select id into v_assessment from public.assessments
  where title='SQL Fundamentals — Demo Assessment' and is_published;

  v_attempt := public.start_assessment_attempt(
    v_assessment,v_candidate_skill,'ci-e2e-verified-skills'
  );
  v_attempt_id := (v_attempt->>'id')::uuid;

  select q.id into v_question
  from public.assessment_questions q
  join public.assessment_sections s on s.id=q.section_id
  where s.assessment_id=v_assessment and q.is_active
  limit 1;

  perform public.save_assessment_answer(v_attempt_id,v_question,'"b"'::jsonb);
  v_result := public.submit_assessment_attempt(v_attempt_id);

  if (v_result->>'passed')::boolean is not true
     or (v_result->>'score')::numeric <> 100
     or v_result->>'status' <> 'verified' then
    raise exception 'E2E scoring result incorrect: %',v_result;
  end if;

  select count(*) into v_badge_count
  from public.skill_verifications sv
  join public.candidate_skills cs on cs.id=sv.candidate_skill_id
  where cs.candidate_id=v_candidate
    and sv.status='verified'
    and sv.badge_code is not null;

  if v_badge_count <> 1 then
    raise exception 'Expected one verified badge, got %',v_badge_count;
  end if;

  raise notice 'PASS: claim -> start -> answer -> server-side score -> verified badge. Result: %',v_result;
end;
$e2e$;

rollback;

-- Final correctness hardening for assessment scoring and candidate profile ownership.
-- Candidate profile identity and demo flags are system-managed, not user-editable.
revoke update on public.candidate_profiles from anon, authenticated;

-- Normalize true/false answers so JSON booleans and "true"/"false" strings
-- compare consistently, while single-choice answers remain exact option IDs.
create or replace function private.submit_assessment_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_attempt public.assessment_attempts%rowtype;
  v_assessment public.assessments%rowtype;
  v_total numeric := 0;
  v_earned numeric := 0;
  v_score numeric := 0;
  v_passed boolean := false;
  v_question_count integer := 0;
  v_answer_count integer := 0;
  v_key_count integer := 0;
  v_result_id uuid;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select aa.* into v_attempt
  from public.assessment_attempts aa
  join public.candidate_profiles cp on cp.id=aa.candidate_id
  where aa.id=p_attempt_id and cp.auth_user_id=v_user
  for update;

  if not found then
    raise exception 'Attempt not found' using errcode = 'P0002';
  end if;

  if v_attempt.status<>'in_progress' then
    raise exception 'Attempt already submitted' using errcode = '23505';
  end if;

  if now()>=v_attempt.expires_at then
    update public.assessment_attempts set status='abandoned' where id=p_attempt_id;
    update public.candidate_skills set status='expired'
      where id=v_attempt.candidate_skill_id and status='in_progress';
    return jsonb_build_object('error','Attempt expired','code','ATTEMPT_EXPIRED');
  end if;

  select * into v_assessment from public.assessments where id=v_attempt.assessment_id;

  select count(*),coalesce(sum(q.points),0)
    into v_question_count,v_total
  from public.assessment_questions q
  join public.assessment_sections s on s.id=q.section_id
  where s.assessment_id=v_attempt.assessment_id and q.is_active;

  select count(*) into v_answer_count
  from public.assessment_answers where attempt_id=p_attempt_id;

  select count(*) into v_key_count
  from public.assessment_questions q
  join public.assessment_sections s on s.id=q.section_id
  join private.assessment_answer_keys k on k.question_id=q.id
  where s.assessment_id=v_attempt.assessment_id and q.is_active;

  if v_question_count=0 or v_answer_count<>v_question_count then
    raise exception 'All active questions must be answered' using errcode='22023';
  end if;

  if v_key_count<>v_question_count then
    raise exception 'Assessment configuration error: answer key missing' using errcode='55000';
  end if;

  select coalesce(sum(q.points) filter (
    where (
      q.question_type='single_choice'
      and aa.answer=k.correct_answers
    ) or (
      q.question_type='true_false'
      and lower(aa.answer #>> '{}')=lower(k.correct_answers #>> '{}')
    ) or (
      q.question_type='multiple_choice'
      and (select coalesce(array_agg(value order by value),array[]::text[])
           from jsonb_array_elements_text(aa.answer) vals(value))
        = (select coalesce(array_agg(value order by value),array[]::text[])
           from jsonb_array_elements_text(k.correct_answers) vals(value))
    )
  ),0)
  into v_earned
  from public.assessment_answers aa
  join public.assessment_questions q on q.id=aa.question_id
  join public.assessment_sections s on s.id=q.section_id
  join private.assessment_answer_keys k on k.question_id=q.id
  where aa.attempt_id=p_attempt_id
    and q.is_active
    and s.assessment_id=v_attempt.assessment_id;

  v_score:=case when v_total=0 then 0 else round((v_earned/v_total)*100,2) end;
  v_passed:=v_score>=v_assessment.passing_score;

  update public.assessment_attempts
  set status='scored',submitted_at=now()
  where id=p_attempt_id;

  insert into public.assessment_results(attempt_id,score,earned_points,total_points,passed)
  values(p_attempt_id,v_score,v_earned,v_total,v_passed)
  returning id into v_result_id;

  insert into public.skill_verifications(
    candidate_skill_id,assessment_result_id,status,verified_at,badge_code
  )
  values(
    v_attempt.candidate_skill_id,v_result_id,
    case when v_passed then 'verified' else 'failed' end,
    case when v_passed then now() else null end,
    case when v_passed then 'VSK-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)) else null end
  );

  update public.candidate_skills
  set status=case when v_passed then 'verified' else 'failed' end,
      last_assessed_at=now()
  where id=v_attempt.candidate_skill_id;

  return jsonb_build_object(
    'attempt_id',p_attempt_id,'result_id',v_result_id,
    'score',v_score,'passed',v_passed,
    'status',case when v_passed then 'verified' else 'failed' end
  );
end;
$function$;
revoke all on function private.submit_assessment_attempt(uuid) from public, anon, authenticated;

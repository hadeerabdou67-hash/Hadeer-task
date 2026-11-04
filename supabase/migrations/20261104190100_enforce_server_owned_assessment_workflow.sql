-- Verified Skills + Assessment Engine: enforce server-owned state transitions.
-- This migration makes the live database rules reproducible from the repository.

-- Candidate claims can only be created through the guarded claim RPC.
drop policy if exists "own candidate skills insert" on public.candidate_skills;
revoke insert, update on public.candidate_skills from anon, authenticated;
grant select, delete on public.candidate_skills to authenticated;

-- Attempts are created only by the start RPC. Never accept client-supplied
-- attempt_number, status, started_at or expires_at.
drop policy if exists "own attempts insert" on public.assessment_attempts;
revoke insert, update, delete on public.assessment_attempts from anon, authenticated;
grant select on public.assessment_attempts to authenticated;

-- Answers are written through a validating RPC so question/attempt association,
-- attempt ownership, expiry and answer format are checked atomically.
drop policy if exists "own answers insert" on public.assessment_answers;
drop policy if exists "own active answers update" on public.assessment_answers;
revoke insert, update, delete on public.assessment_answers from anon, authenticated;
grant select on public.assessment_answers to authenticated;

-- Private schema is not an API surface. SECURITY DEFINER wrappers below are
-- the only client-callable entry points.
revoke all on schema private from public, anon, authenticated;

create or replace function private.validate_assessment_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_candidate_id uuid;
  v_assessment_skill_id uuid;
begin
  select cs.candidate_id, cs.skill_id
    into v_candidate_id, v_assessment_skill_id
  from public.candidate_skills cs
  where cs.id = new.candidate_skill_id;

  if not found or v_candidate_id <> new.candidate_id then
    raise exception 'Candidate skill does not belong to candidate' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.assessments a
    where a.id = new.assessment_id
      and a.skill_id = v_assessment_skill_id
  ) then
    raise exception 'Assessment does not assess the claimed skill' using errcode = '23514';
  end if;

  return new;
end;
$function$;
revoke all on function private.validate_assessment_attempt() from public, anon, authenticated;
drop trigger if exists validate_assessment_attempt on public.assessment_attempts;
create trigger validate_assessment_attempt
before insert or update of candidate_id, candidate_skill_id, assessment_id
on public.assessment_attempts
for each row execute function private.validate_assessment_attempt();

create or replace function private.claim_candidate_skill(p_skill_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_candidate_id uuid;
  v_claim public.candidate_skills%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select cp.id into v_candidate_id
  from public.candidate_profiles cp
  where cp.auth_user_id = auth.uid()
  for update;

  if v_candidate_id is null then
    raise exception 'Candidate profile not found' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.skills s where s.id=p_skill_id and s.is_active) then
    raise exception 'Active skill not found' using errcode = 'P0002';
  end if;

  insert into public.candidate_skills(candidate_id, skill_id, status)
  values (v_candidate_id, p_skill_id, 'claimed')
  returning * into v_claim;

  return jsonb_build_object(
    'id', v_claim.id,
    'skill_id', v_claim.skill_id,
    'status', v_claim.status,
    'claimed_at', v_claim.claimed_at
  );
end;
$function$;
revoke all on function private.claim_candidate_skill(uuid) from public, anon, authenticated;

create or replace function public.claim_candidate_skill(p_skill_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select private.claim_candidate_skill(p_skill_id);
$function$;
revoke all on function public.claim_candidate_skill(uuid) from public, anon;
grant execute on function public.claim_candidate_skill(uuid) to authenticated;

-- Keep the start-attempt implementation in migrations (it previously existed
-- only in the live database). The candidate row lock serializes attempt creation
-- and protects attempt limits/cooldowns from concurrent requests.
create or replace function private.start_assessment_attempt(
  p_assessment_id uuid,
  p_candidate_skill_id uuid,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_candidate_id uuid;
  v_assessment public.assessments%rowtype;
  v_candidate_skill public.candidate_skills%rowtype;
  v_existing public.assessment_attempts%rowtype;
  v_attempt public.assessment_attempts%rowtype;
  v_attempt_count integer;
  v_last_started timestamptz;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_idempotency_key is not null and
     (length(btrim(p_idempotency_key)) = 0 or length(p_idempotency_key) > 128) then
    raise exception 'Invalid idempotency key' using errcode = '22023';
  end if;

  select cp.id into v_candidate_id
  from public.candidate_profiles cp
  where cp.auth_user_id = v_user
  for update;

  if v_candidate_id is null then
    raise exception 'Candidate profile not found' using errcode = 'P0002';
  end if;

  if p_idempotency_key is not null then
    select * into v_existing
    from public.assessment_attempts aa
    where aa.candidate_id = v_candidate_id
      and aa.idempotency_key = p_idempotency_key;

    if found then
      if v_existing.assessment_id <> p_assessment_id then
        raise exception 'Idempotency key already used for another assessment' using errcode = '23505';
      end if;
      return jsonb_build_object(
        'id',v_existing.id,'assessment_id',v_existing.assessment_id,
        'attempt_number',v_existing.attempt_number,'status',v_existing.status,
        'started_at',v_existing.started_at,'expires_at',v_existing.expires_at,'reused',true
      );
    end if;
  end if;

  select * into v_assessment
  from public.assessments a
  where a.id=p_assessment_id and a.is_published=true;

  if not found then
    raise exception 'Published assessment not found' using errcode = 'P0002';
  end if;

  select * into v_candidate_skill
  from public.candidate_skills cs
  where cs.id=p_candidate_skill_id
    and cs.candidate_id=v_candidate_id
    and cs.skill_id=v_assessment.skill_id
  for update;

  if not found then
    raise exception 'Claim the matching skill before starting' using errcode = '42501';
  end if;

  select count(*), max(started_at)
    into v_attempt_count, v_last_started
  from public.assessment_attempts
  where candidate_id=v_candidate_id
    and assessment_id=p_assessment_id;

  if v_attempt_count >= v_assessment.max_attempts then
    raise exception 'Maximum attempts reached' using errcode = 'P0001';
  end if;

  if v_last_started is not null
     and v_assessment.retake_cooldown_hours > 0
     and v_last_started + make_interval(hours => v_assessment.retake_cooldown_hours) > now() then
    raise exception 'Retake cooldown is active' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.assessment_attempts aa
    where aa.candidate_id=v_candidate_id
      and aa.assessment_id=p_assessment_id
      and aa.status='in_progress'
      and aa.expires_at > now()
  ) then
    raise exception 'An active attempt already exists' using errcode = 'P0001';
  end if;

  update public.assessment_attempts
  set status='abandoned'
  where candidate_id=v_candidate_id
    and assessment_id=p_assessment_id
    and status='in_progress'
    and expires_at <= now();

  insert into public.assessment_attempts(
    candidate_id,candidate_skill_id,assessment_id,attempt_number,status,expires_at,idempotency_key
  )
  values (
    v_candidate_id,p_candidate_skill_id,p_assessment_id,v_attempt_count+1,'in_progress',
    now()+make_interval(mins => v_assessment.duration_minutes),p_idempotency_key
  )
  returning * into v_attempt;

  update public.candidate_skills
  set status='in_progress'
  where id=p_candidate_skill_id;

  return jsonb_build_object(
    'id',v_attempt.id,'assessment_id',v_attempt.assessment_id,
    'attempt_number',v_attempt.attempt_number,'status',v_attempt.status,
    'started_at',v_attempt.started_at,'expires_at',v_attempt.expires_at,'reused',false
  );
end;
$function$;
revoke all on function private.start_assessment_attempt(uuid,uuid,text) from public, anon, authenticated;

create or replace function public.start_assessment_attempt(
  p_assessment_id uuid,
  p_candidate_skill_id uuid,
  p_idempotency_key text default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select private.start_assessment_attempt(p_assessment_id,p_candidate_skill_id,p_idempotency_key);
$function$;
revoke all on function public.start_assessment_attempt(uuid,uuid,text) from public, anon;
grant execute on function public.start_assessment_attempt(uuid,uuid,text) to authenticated;

create or replace function private.save_assessment_answer(
  p_attempt_id uuid,
  p_question_id uuid,
  p_answer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_attempt public.assessment_attempts%rowtype;
  v_question public.assessment_questions%rowtype;
  v_candidate_id uuid;
  v_option_count integer := 0;
  v_distinct_option_count integer := 0;
  v_all_options_valid boolean := false;
  v_saved public.assessment_answers%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select aa.* into v_attempt
  from public.assessment_attempts aa
  join public.candidate_profiles cp on cp.id=aa.candidate_id
  where aa.id=p_attempt_id and cp.auth_user_id=auth.uid()
  for update of aa;

  if not found then
    raise exception 'Attempt not found' using errcode = 'P0002';
  end if;

  if v_attempt.status <> 'in_progress' then
    raise exception 'Attempt is not active' using errcode = 'P0001';
  end if;

  if now() >= v_attempt.expires_at then
    update public.assessment_attempts set status='abandoned' where id=p_attempt_id;
    update public.candidate_skills set status='expired'
      where id=v_attempt.candidate_skill_id and status='in_progress';
    return jsonb_build_object('code','ATTEMPT_EXPIRED','error','Attempt expired');
  end if;

  select q.* into v_question
  from public.assessment_questions q
  join public.assessment_sections s on s.id=q.section_id
  where q.id=p_question_id
    and q.is_active
    and s.assessment_id=v_attempt.assessment_id;

  if not found then
    raise exception 'Question does not belong to this assessment' using errcode = '22023';
  end if;

  if jsonb_typeof(v_question.options) <> 'array' then
    raise exception 'Question options are not configured correctly' using errcode = '55000';
  end if;

  if v_question.question_type='single_choice' then
    if jsonb_typeof(p_answer) <> 'string' then
      raise exception 'Single-choice answer must be an option ID' using errcode = '22023';
    end if;
    if not exists (
      select 1 from jsonb_array_elements(v_question.options) opt
      where opt->>'id'=p_answer #>> '{}'
    ) then
      raise exception 'Selected option is invalid' using errcode = '22023';
    end if;
  elsif v_question.question_type='true_false' then
    if jsonb_typeof(p_answer)<>'boolean' then
      raise exception 'True/false answer must be a boolean' using errcode = '22023';
    end if;
  elsif v_question.question_type='multiple_choice' then
    if jsonb_typeof(p_answer)<>'array' or jsonb_array_length(p_answer)=0 then
      raise exception 'Multiple-choice answer must be a non-empty array of option IDs' using errcode = '22023';
    end if;

    select count(*),count(distinct val),coalesce(bool_and(exists(
      select 1 from jsonb_array_elements(v_question.options) opt where opt->>'id'=val
    )),false)
    into v_option_count,v_distinct_option_count,v_all_options_valid
    from jsonb_array_elements_text(p_answer) vals(val);

    if v_option_count<>jsonb_array_length(p_answer)
       or v_option_count<>v_distinct_option_count
       or not v_all_options_valid then
      raise exception 'Multiple-choice answer contains invalid or duplicate options' using errcode = '22023';
    end if;
  else
    raise exception 'Unsupported question type' using errcode = '22023';
  end if;

  insert into public.assessment_answers(attempt_id,question_id,answer,answered_at)
  values (p_attempt_id,p_question_id,p_answer,now())
  on conflict (attempt_id,question_id)
  do update set answer=excluded.answer,answered_at=excluded.answered_at
  returning * into v_saved;

  return jsonb_build_object(
    'id',v_saved.id,'attempt_id',v_saved.attempt_id,
    'question_id',v_saved.question_id,'answered_at',v_saved.answered_at
  );
end;
$function$;
revoke all on function private.save_assessment_answer(uuid,uuid,jsonb) from public, anon, authenticated;

create or replace function public.save_assessment_answer(
  p_attempt_id uuid,
  p_question_id uuid,
  p_answer jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select private.save_assessment_answer(p_attempt_id,p_question_id,p_answer);
$function$;
revoke all on function public.save_assessment_answer(uuid,uuid,jsonb) from public, anon;
grant execute on function public.save_assessment_answer(uuid,uuid,jsonb) to authenticated;

-- Preserve expiry as a committed state transition instead of raising an
-- exception after updating (which would roll the update back).
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

  select * into v_assessment
  from public.assessments
  where id=v_attempt.assessment_id;

  select count(*),coalesce(sum(q.points),0)
    into v_question_count,v_total
  from public.assessment_questions q
  join public.assessment_sections s on s.id=q.section_id
  where s.assessment_id=v_attempt.assessment_id and q.is_active;

  select count(*) into v_answer_count
  from public.assessment_answers
  where attempt_id=p_attempt_id;

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
    where (q.question_type in ('single_choice','true_false') and aa.answer=k.correct_answers)
       or (q.question_type='multiple_choice'
          and (select coalesce(array_agg(value order by value),array[]::text[])
               from jsonb_array_elements_text(aa.answer) vals(value))
           = (select coalesce(array_agg(value order by value),array[]::text[])
               from jsonb_array_elements_text(k.correct_answers) vals(value)))
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

create or replace function public.submit_assessment_attempt(p_attempt_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select private.submit_assessment_attempt(p_attempt_id);
$function$;
revoke all on function public.submit_assessment_attempt(uuid) from public, anon;
grant execute on function public.submit_assessment_attempt(uuid) to authenticated;

-- No direct client access to the answer-key schema or its tables.
revoke all on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

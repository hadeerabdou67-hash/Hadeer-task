-- Verified Skills + Assessment Engine: transactional and authorization hardening.
-- Existing candidate data and assessment history are preserved.

create or replace function private.guard_candidate_skill_status()
returns trigger language plpgsql security invoker set search_path = ''
as $function$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'claimed' then
      raise exception 'Candidate skill status must start as claimed' using errcode = '42501';
    end if;
  elsif new.status is distinct from old.status and current_user <> 'postgres' then
    raise exception 'Candidate skill status is managed by the assessment engine' using errcode = '42501';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_guard_candidate_skill_status on public.candidate_skills;
create trigger trg_guard_candidate_skill_status
before insert or update of status on public.candidate_skills
for each row execute function private.guard_candidate_skill_status();

drop policy if exists "own candidate skills insert" on public.candidate_skills;
drop policy if exists "own claimed candidate skills insert" on public.candidate_skills;
create policy "own claimed candidate skills insert" on public.candidate_skills
for insert to authenticated
with check (
  status = 'claimed'
  and exists (select 1 from public.candidate_profiles cp
              where cp.id = candidate_id and cp.auth_user_id = (select auth.uid()))
);

drop policy if exists "own attempts insert" on public.assessment_attempts;
revoke insert, update, delete on public.assessment_attempts from anon, authenticated;
grant select on public.assessment_attempts to authenticated;

create or replace function private.start_assessment_attempt(
  p_assessment_id uuid, p_candidate_skill_id uuid, p_idempotency_key text default null
)
returns jsonb language plpgsql security definer set search_path = ''
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
  if v_user is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_idempotency_key is not null and
     (length(btrim(p_idempotency_key)) = 0 or length(p_idempotency_key) > 128) then
    raise exception 'Invalid idempotency key' using errcode = '22023';
  end if;

  select cp.id into v_candidate_id from public.candidate_profiles cp
  where cp.auth_user_id = v_user for update;
  if v_candidate_id is null then raise exception 'Candidate profile not found' using errcode = 'P0002'; end if;

  if p_idempotency_key is not null then
    select * into v_existing from public.assessment_attempts aa
    where aa.candidate_id = v_candidate_id and aa.idempotency_key = p_idempotency_key;
    if found then
      if v_existing.assessment_id <> p_assessment_id then
        raise exception 'Idempotency key was already used for another assessment' using errcode = '23505';
      end if;
      return jsonb_build_object('id',v_existing.id,'assessment_id',v_existing.assessment_id,
        'attempt_number',v_existing.attempt_number,'status',v_existing.status,
        'started_at',v_existing.started_at,'expires_at',v_existing.expires_at,'reused',true);
    end if;
  end if;

  select * into v_assessment from public.assessments a
  where a.id = p_assessment_id and a.is_published = true;
  if not found then raise exception 'Published assessment not found' using errcode = 'P0002'; end if;

  select * into v_candidate_skill from public.candidate_skills cs
  where cs.id = p_candidate_skill_id and cs.candidate_id = v_candidate_id
    and cs.skill_id = v_assessment.skill_id for update;
  if not found then raise exception 'Claim the matching skill before starting' using errcode = '42501'; end if;

  update public.assessment_attempts set status = 'abandoned'
  where candidate_id = v_candidate_id and assessment_id = p_assessment_id
    and status = 'in_progress' and expires_at <= now();

  select count(*), max(started_at) into v_attempt_count, v_last_started
  from public.assessment_attempts
  where candidate_id = v_candidate_id and assessment_id = p_assessment_id;

  if v_attempt_count >= v_assessment.max_attempts then
    raise exception 'Maximum attempts reached' using errcode = 'P0001';
  end if;
  if v_last_started is not null and v_assessment.retake_cooldown_hours > 0
     and v_last_started + make_interval(hours => v_assessment.retake_cooldown_hours) > now() then
    raise exception 'Retake cooldown is active' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.assessment_attempts aa
    where aa.candidate_id = v_candidate_id and aa.assessment_id = p_assessment_id
      and aa.status = 'in_progress' and aa.expires_at > now()) then
    raise exception 'An active attempt already exists' using errcode = 'P0001';
  end if;

  insert into public.assessment_attempts(
    candidate_id,candidate_skill_id,assessment_id,attempt_number,status,expires_at,idempotency_key
  ) values (
    v_candidate_id,p_candidate_skill_id,p_assessment_id,v_attempt_count+1,'in_progress',
    now()+make_interval(mins => v_assessment.duration_minutes),p_idempotency_key
  ) returning * into v_attempt;

  update public.candidate_skills set status='in_progress' where id=p_candidate_skill_id;

  return jsonb_build_object('id',v_attempt.id,'assessment_id',v_attempt.assessment_id,
    'attempt_number',v_attempt.attempt_number,'status',v_attempt.status,
    'started_at',v_attempt.started_at,'expires_at',v_attempt.expires_at,'reused',false);
end;
$function$;
revoke all on function private.start_assessment_attempt(uuid,uuid,text) from public,anon,authenticated;

create or replace function public.start_assessment_attempt(
  p_assessment_id uuid, p_candidate_skill_id uuid, p_idempotency_key text default null
)
returns jsonb language sql security definer set search_path = ''
as $function$ select private.start_assessment_attempt(p_assessment_id,p_candidate_skill_id,p_idempotency_key); $function$;
revoke all on function public.start_assessment_attempt(uuid,uuid,text) from public,anon;
grant execute on function public.start_assessment_attempt(uuid,uuid,text) to authenticated;

create or replace function private.validate_assessment_answer()
returns trigger language plpgsql security invoker set search_path = ''
as $function$
declare
  v_type text;
  v_options jsonb;
  v_attempt public.assessment_attempts%rowtype;
  v_option_count integer;
  v_distinct_count integer;
begin
  select aa.* into v_attempt
  from public.assessment_attempts aa
  join public.candidate_profiles cp on cp.id=aa.candidate_id
  where aa.id=new.attempt_id and cp.auth_user_id=auth.uid();
  if not found then raise exception 'Attempt not found' using errcode='42501'; end if;
  if v_attempt.status <> 'in_progress' or v_attempt.expires_at <= now() then
    raise exception 'Attempt is not active' using errcode='23514';
  end if;

  select q.question_type,q.options into v_type,v_options
  from public.assessment_questions q
  join public.assessment_sections s on s.id=q.section_id
  where q.id=new.question_id and q.is_active and s.assessment_id=v_attempt.assessment_id;
  if not found then raise exception 'Question does not belong to this active assessment' using errcode='23514'; end if;

  if v_type='true_false' then
    if jsonb_typeof(new.answer) <> 'boolean' then
      raise exception 'True/false answer must be boolean' using errcode='22023';
    end if;
  elsif v_type='single_choice' then
    if jsonb_typeof(new.answer) <> 'string' or not exists (
      select 1 from jsonb_array_elements(v_options) opt where opt->>'id'=new.answer #>> '{}'
    ) then raise exception 'Invalid single-choice option' using errcode='22023'; end if;
  elsif v_type='multiple_choice' then
    if jsonb_typeof(new.answer) <> 'array' then
      raise exception 'Multiple-choice answer must be an array' using errcode='22023';
    end if;
    select count(*),count(distinct value) into v_option_count,v_distinct_count
    from jsonb_array_elements_text(new.answer) vals(value);
    if v_option_count=0 or v_option_count<>v_distinct_count or exists (
      select 1 from jsonb_array_elements_text(new.answer) vals(value)
      where not exists (select 1 from jsonb_array_elements(v_options) opt where opt->>'id'=vals.value)
    ) then raise exception 'Invalid multiple-choice options' using errcode='22023'; end if;
  else
    raise exception 'Unsupported question type' using errcode='22023';
  end if;

  new.answered_at:=now();
  return new;
end;
$function$;
drop trigger if exists trg_validate_assessment_answer on public.assessment_answers;
create trigger trg_validate_assessment_answer
before insert or update on public.assessment_answers
for each row execute function private.validate_assessment_answer();

create or replace function private.submit_assessment_attempt(p_attempt_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
  v_user uuid:=auth.uid();
  v_attempt public.assessment_attempts%rowtype;
  v_assessment public.assessments%rowtype;
  v_total numeric:=0;
  v_earned numeric:=0;
  v_score numeric:=0;
  v_passed boolean:=false;
  v_question_count integer:=0;
  v_answer_count integer:=0;
  v_key_count integer:=0;
  v_result_id uuid;
begin
  if v_user is null then raise exception 'Authentication required' using errcode='42501'; end if;

  select aa.* into v_attempt from public.assessment_attempts aa
  join public.candidate_profiles cp on cp.id=aa.candidate_id
  where aa.id=p_attempt_id and cp.auth_user_id=v_user for update;
  if not found then raise exception 'Attempt not found' using errcode='P0002'; end if;
  if v_attempt.status<>'in_progress' then raise exception 'Attempt already submitted' using errcode='23505'; end if;

  if now()>=v_attempt.expires_at then
    update public.assessment_attempts set status='abandoned' where id=p_attempt_id;
    update public.candidate_skills set status='expired'
      where id=v_attempt.candidate_skill_id and status='in_progress';
    return jsonb_build_object('error','Attempt expired','code','ATTEMPT_EXPIRED');
  end if;

  select * into v_assessment from public.assessments where id=v_attempt.assessment_id;
  select count(*),coalesce(sum(q.points),0) into v_question_count,v_total
  from public.assessment_questions q join public.assessment_sections s on s.id=q.section_id
  where s.assessment_id=v_attempt.assessment_id and q.is_active;
  select count(*) into v_answer_count from public.assessment_answers where attempt_id=p_attempt_id;
  select count(*) into v_key_count
  from public.assessment_questions q join public.assessment_sections s on s.id=q.section_id
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
  ),0) into v_earned
  from public.assessment_answers aa
  join public.assessment_questions q on q.id=aa.question_id
  join public.assessment_sections s on s.id=q.section_id
  join private.assessment_answer_keys k on k.question_id=q.id
  where aa.attempt_id=p_attempt_id and q.is_active and s.assessment_id=v_attempt.assessment_id;

  v_score:=case when v_total=0 then 0 else round((v_earned/v_total)*100,2) end;
  v_passed:=v_score>=v_assessment.passing_score;

  update public.assessment_attempts set status='scored',submitted_at=now() where id=p_attempt_id;
  insert into public.assessment_results(attempt_id,score,earned_points,total_points,passed)
  values(p_attempt_id,v_score,v_earned,v_total,v_passed) returning id into v_result_id;
  insert into public.skill_verifications(candidate_skill_id,assessment_result_id,status,verified_at,badge_code)
  values(v_attempt.candidate_skill_id,v_result_id,
    case when v_passed then 'verified' else 'failed' end,
    case when v_passed then now() else null end,
    case when v_passed then 'VSK-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)) else null end);
  update public.candidate_skills set status=case when v_passed then 'verified' else 'failed' end,
    last_assessed_at=now() where id=v_attempt.candidate_skill_id;

  return jsonb_build_object('attempt_id',p_attempt_id,'result_id',v_result_id,
    'score',v_score,'passed',v_passed,'status',case when v_passed then 'verified' else 'failed' end);
end;
$function$;
revoke all on function private.submit_assessment_attempt(uuid) from public,anon,authenticated;

revoke insert,update,delete on public.assessment_results,public.skill_verifications from anon,authenticated;
revoke usage on schema private from anon,authenticated;

create index if not exists idx_attempts_candidate_skill on public.assessment_attempts(candidate_skill_id);
create index if not exists idx_answers_question on public.assessment_answers(question_id);

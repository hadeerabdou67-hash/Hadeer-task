-- Final integrity and concurrency hardening.
-- Composite FK ensures an attempt cannot reference another candidate's skill claim.
alter table public.candidate_skills
  add constraint candidate_skills_id_candidate_unique unique (id, candidate_id);

alter table public.assessment_attempts
  add constraint attempts_candidate_skill_owner_fk
  foreign key (candidate_skill_id, candidate_id)
  references public.candidate_skills(id, candidate_id)
  on delete cascade;

-- Serialize answer writes against submission/scoring on the same attempt.
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
  where aa.id=new.attempt_id and cp.auth_user_id=auth.uid()
  for update of aa;
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

-- Remove duplicate indexes identified by the Performance Advisor.
drop index if exists public.idx_assessment_attempts_candidate_skill_id;
drop index if exists public.idx_assessment_answers_question_id;

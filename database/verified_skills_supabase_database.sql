-- =============================================================
-- Verified Skills + Assessment Engine
-- Consolidated database schema + security + demo seed SQL
-- Source: hadeerabdou67-hash/Hadeer-task @ feature/person-3-assessments
-- Generated from the exact ordered migration files listed below.
--
-- IMPORTANT:
-- * Intended for a NEW Supabase project/database with Supabase Auth available.
-- * This is a schema-and-fixture installer, NOT a backup of user/auth records.
-- * It does not include live candidate PII or authentication credentials.
-- * For an already provisioned project, do NOT run this whole file again.
--   Use the original timestamped migrations and reconcile migration history.
-- =============================================================



-- =============================================================
-- SOURCE MIGRATION 1/11: supabase/migrations/20261104150000_verified_skills_assessment.sql
-- =============================================================

-- Verified Skills + Assessment Engine
-- Apply with: supabase db push (or review and run in Supabase SQL editor).
create extension if not exists pgcrypto;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.skill_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique,
  description text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.skills (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.skill_categories(id) on delete restrict,
  name text not null,
  slug text not null unique,
  description text,
  level text not null default 'intermediate' check (level in ('beginner','intermediate','advanced','expert')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(category_id, name)
);

create table if not exists public.candidate_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete cascade,
  external_ref text unique,
  display_name text,
  is_demo boolean not null default false,
  created_at timestamptz not null default now(),
  check (auth_user_id is not null or external_ref is not null)
);

create table if not exists public.candidate_skills (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidate_profiles(id) on delete cascade,
  skill_id uuid not null references public.skills(id) on delete restrict,
  status text not null default 'claimed' check (status in ('claimed','in_progress','verified','failed','expired')),
  claimed_at timestamptz not null default now(),
  last_assessed_at timestamptz,
  unique(candidate_id, skill_id)
);

create table if not exists public.skill_evidence (
  id uuid primary key default gen_random_uuid(),
  candidate_skill_id uuid not null references public.candidate_skills(id) on delete cascade,
  evidence_type text not null check (evidence_type in ('url','document','certificate','portfolio','note')),
  title text not null,
  uri text,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  submitted_at timestamptz not null default now()
);

create table if not exists public.assessments (
  id uuid primary key default gen_random_uuid(),
  skill_id uuid not null references public.skills(id) on delete cascade,
  title text not null,
  description text,
  passing_score numeric(5,2) not null default 70 check (passing_score between 0 and 100),
  duration_minutes integer not null default 30 check (duration_minutes between 1 and 600),
  max_attempts integer not null default 3 check (max_attempts between 1 and 20),
  retake_cooldown_hours integer not null default 24 check (retake_cooldown_hours >= 0),
  is_published boolean not null default false,
  version integer not null default 1,
  created_at timestamptz not null default now()
);

create table if not exists public.assessment_sections (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  title text not null,
  description text,
  sort_order integer not null default 0
);

create table if not exists public.assessment_questions (
  id uuid primary key default gen_random_uuid(),
  section_id uuid not null references public.assessment_sections(id) on delete cascade,
  question_type text not null default 'single_choice' check (question_type in ('single_choice','multiple_choice','true_false')),
  prompt text not null,
  options jsonb not null default '[]'::jsonb,
  points numeric(8,2) not null default 1 check (points > 0),
  sort_order integer not null default 0,
  explanation text,
  is_active boolean not null default true
);

-- Answer keys live in a non-exposed schema. Never return these rows to clients.
create table if not exists private.assessment_answer_keys (
  question_id uuid primary key references public.assessment_questions(id) on delete cascade,
  correct_answers jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.assessment_attempts (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidate_profiles(id) on delete cascade,
  candidate_skill_id uuid not null references public.candidate_skills(id) on delete cascade,
  assessment_id uuid not null references public.assessments(id) on delete restrict,
  attempt_number integer not null check (attempt_number > 0),
  status text not null default 'in_progress' check (status in ('in_progress','submitted','scored','abandoned')),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  expires_at timestamptz not null,
  idempotency_key text,
  unique(candidate_id, assessment_id, attempt_number),
  unique(candidate_id, idempotency_key)
);

create table if not exists public.assessment_answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.assessment_attempts(id) on delete cascade,
  question_id uuid not null references public.assessment_questions(id) on delete restrict,
  answer jsonb not null,
  answered_at timestamptz not null default now(),
  unique(attempt_id, question_id)
);

create table if not exists public.assessment_results (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null unique references public.assessment_attempts(id) on delete cascade,
  score numeric(7,2) not null check (score between 0 and 100),
  earned_points numeric(10,2) not null,
  total_points numeric(10,2) not null,
  passed boolean not null,
  scored_at timestamptz not null default now(),
  breakdown jsonb not null default '{}'::jsonb
);

create table if not exists public.skill_verifications (
  id uuid primary key default gen_random_uuid(),
  candidate_skill_id uuid not null references public.candidate_skills(id) on delete cascade,
  assessment_result_id uuid not null unique references public.assessment_results(id) on delete cascade,
  status text not null check (status in ('verified','failed','revoked','expired')),
  verified_at timestamptz,
  expires_at timestamptz,
  badge_code text unique,
  created_at timestamptz not null default now()
);

create index if not exists idx_skills_category on public.skills(category_id);
create index if not exists idx_candidate_skills_candidate on public.candidate_skills(candidate_id);
create index if not exists idx_assessments_skill_published on public.assessments(skill_id, is_published);
create index if not exists idx_attempts_candidate_assessment on public.assessment_attempts(candidate_id, assessment_id, started_at desc);
create index if not exists idx_verifications_candidate_skill on public.skill_verifications(candidate_skill_id, created_at desc);

-- Candidate profile is created lazily from the authenticated identity.
create or replace function private.ensure_candidate_profile()
returns uuid language plpgsql security definer set search_path = ''
as $function$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  insert into public.candidate_profiles(auth_user_id)
  values (auth.uid())
  on conflict (auth_user_id) do update set auth_user_id = excluded.auth_user_id
  returning id into v_id;
  return v_id;
end;
$function$;
revoke all on function private.ensure_candidate_profile() from public, anon;
grant execute on function private.ensure_candidate_profile() to authenticated;

create or replace function public.ensure_candidate_profile()
returns uuid language sql security invoker set search_path = ''
as $function$ select private.ensure_candidate_profile(); $function$;
revoke all on function public.ensure_candidate_profile() from public, anon;
grant execute on function public.ensure_candidate_profile() to authenticated;

-- Submit and score atomically inside Postgres. Answer keys are never selected by API queries.
create or replace function private.submit_assessment_attempt(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  v_result_id uuid;
  v_badge text;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  select a.* into v_attempt
  from public.assessment_attempts a
  join public.candidate_profiles cp on cp.id = a.candidate_id
  where a.id = p_attempt_id and cp.auth_user_id = v_user
  for update;
  if not found then raise exception 'Attempt not found' using errcode = 'P0002'; end if;
  if v_attempt.status <> 'in_progress' then raise exception 'Attempt already submitted' using errcode = '23505'; end if;
  if now() > v_attempt.expires_at then
    update public.assessment_attempts set status = 'abandoned' where id = p_attempt_id;
    raise exception 'Attempt expired' using errcode = '22023';
  end if;
  select * into v_assessment from public.assessments where id = v_attempt.assessment_id;
  select count(*), coalesce(sum(q.points),0)
    into v_question_count, v_total
  from public.assessment_questions q
  join public.assessment_sections s on s.id = q.section_id
  where s.assessment_id = v_attempt.assessment_id and q.is_active;
  select count(*) into v_answer_count from public.assessment_answers where attempt_id = p_attempt_id;
  if v_question_count = 0 or v_answer_count <> v_question_count then
    raise exception 'All active questions must be answered' using errcode = '22023';
  end if;

  select coalesce(sum(q.points) filter (
    where (q.question_type = 'single_choice' and aa.answer = k.correct_answers)
       or (q.question_type = 'true_false' and aa.answer = k.correct_answers)
       or (q.question_type = 'multiple_choice' and
           (select coalesce(array_agg(value order by value), array[]::text[]) from jsonb_array_elements_text(aa.answer) as answer_values(value))
           =
           (select coalesce(array_agg(value order by value), array[]::text[]) from jsonb_array_elements_text(k.correct_answers) as key_values(value)))
  ),0)
  into v_earned
  from public.assessment_answers aa
  join public.assessment_questions q on q.id = aa.question_id
  join public.assessment_sections s on s.id = q.section_id
  join private.assessment_answer_keys k on k.question_id = q.id
  where aa.attempt_id = p_attempt_id and q.is_active and s.assessment_id = v_attempt.assessment_id;

  v_score := case when v_total = 0 then 0 else round((v_earned / v_total) * 100, 2) end;
  v_passed := v_score >= v_assessment.passing_score;

  update public.assessment_attempts
    set status = 'scored', submitted_at = now()
    where id = p_attempt_id;

  insert into public.assessment_results(attempt_id, score, earned_points, total_points, passed)
  values (p_attempt_id, v_score, v_earned, v_total, v_passed)
  returning id into v_result_id;

  insert into public.skill_verifications(candidate_skill_id, assessment_result_id, status, verified_at, badge_code)
  values (v_attempt.candidate_skill_id, v_result_id,
          case when v_passed then 'verified' else 'failed' end,
          case when v_passed then now() else null end,
          case when v_passed then 'VSK-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)) else null end);

  update public.candidate_skills
  set status = case when v_passed then 'verified' else 'failed' end,
      last_assessed_at = now()
  where id = v_attempt.candidate_skill_id;

  return jsonb_build_object('attempt_id',p_attempt_id,'result_id',v_result_id,
    'score',v_score,'passed',v_passed,'status',case when v_passed then 'verified' else 'failed' end);
end;
$$;
revoke all on function private.submit_assessment_attempt(uuid) from public, anon;
grant execute on function private.submit_assessment_attempt(uuid) to authenticated;

create or replace function public.submit_assessment_attempt(p_attempt_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $function$ select private.submit_assessment_attempt(p_attempt_id); $function$;
revoke all on function public.submit_assessment_attempt(uuid) from public, anon;
grant execute on function public.submit_assessment_attempt(uuid) to authenticated;

-- Lock down all exposed tables; candidates can only access their own rows.
alter table public.skill_categories enable row level security;
alter table public.skills enable row level security;
alter table public.candidate_profiles enable row level security;
alter table public.candidate_skills enable row level security;
alter table public.skill_evidence enable row level security;
alter table public.assessments enable row level security;
alter table public.assessment_sections enable row level security;
alter table public.assessment_questions enable row level security;
alter table public.assessment_attempts enable row level security;
alter table public.assessment_answers enable row level security;
alter table public.assessment_results enable row level security;
alter table public.skill_verifications enable row level security;
alter table private.assessment_answer_keys enable row level security;

create policy "taxonomy readable by authenticated" on public.skill_categories for select to authenticated using (true);
create policy "skills readable by authenticated" on public.skills for select to authenticated using (is_active);
create policy "own candidate profile read" on public.candidate_profiles for select to authenticated using (auth_user_id = (select auth.uid()));
create policy "own candidate profile update" on public.candidate_profiles for update to authenticated using (auth_user_id = (select auth.uid())) with check (auth_user_id = (select auth.uid()));
create policy "own candidate skills read" on public.candidate_skills for select to authenticated using (exists(select 1 from public.candidate_profiles cp where cp.id=candidate_id and cp.auth_user_id=(select auth.uid())));
create policy "own candidate skills insert" on public.candidate_skills for insert to authenticated with check (exists(select 1 from public.candidate_profiles cp where cp.id=candidate_id and cp.auth_user_id=(select auth.uid())));
create policy "own candidate skills delete" on public.candidate_skills for delete to authenticated using (exists(select 1 from public.candidate_profiles cp where cp.id=candidate_id and cp.auth_user_id=(select auth.uid())));
create policy "own evidence read" on public.skill_evidence for select to authenticated using (exists(select 1 from public.candidate_skills cs join public.candidate_profiles cp on cp.id=cs.candidate_id where cs.id=candidate_skill_id and cp.auth_user_id=(select auth.uid())));
create policy "own evidence insert" on public.skill_evidence for insert to authenticated with check (exists(select 1 from public.candidate_skills cs join public.candidate_profiles cp on cp.id=cs.candidate_id where cs.id=candidate_skill_id and cp.auth_user_id=(select auth.uid())));
create policy "published assessments readable" on public.assessments for select to authenticated using (is_published);
create policy "sections of published assessments readable" on public.assessment_sections for select to authenticated using (exists(select 1 from public.assessments a where a.id=assessment_id and a.is_published));
create policy "questions of published assessments readable" on public.assessment_questions for select to authenticated using (is_active and exists(select 1 from public.assessment_sections s join public.assessments a on a.id=s.assessment_id where s.id=section_id and a.is_published));
create policy "own attempts read" on public.assessment_attempts for select to authenticated using (exists(select 1 from public.candidate_profiles cp where cp.id=candidate_id and cp.auth_user_id=(select auth.uid())));
create policy "own attempts insert" on public.assessment_attempts for insert to authenticated with check (exists(select 1 from public.candidate_profiles cp where cp.id=candidate_id and cp.auth_user_id=(select auth.uid())));
create policy "own answers read" on public.assessment_answers for select to authenticated using (exists(select 1 from public.assessment_attempts a join public.candidate_profiles cp on cp.id=a.candidate_id where a.id=attempt_id and cp.auth_user_id=(select auth.uid())));
create policy "own answers insert" on public.assessment_answers for insert to authenticated with check (exists(select 1 from public.assessment_attempts a join public.candidate_profiles cp on cp.id=a.candidate_id where a.id=attempt_id and a.status='in_progress' and a.expires_at > now() and cp.auth_user_id=(select auth.uid())));
create policy "own results read" on public.assessment_results for select to authenticated using (exists(select 1 from public.assessment_attempts a join public.candidate_profiles cp on cp.id=a.candidate_id where a.id=attempt_id and cp.auth_user_id=(select auth.uid())));
create policy "own verifications read" on public.skill_verifications for select to authenticated using (exists(select 1 from public.candidate_skills cs join public.candidate_profiles cp on cp.id=cs.candidate_id where cs.id=candidate_skill_id and cp.auth_user_id=(select auth.uid())));

revoke all on all tables in schema public from anon, authenticated;
grant usage on schema public to authenticated;
grant select on public.skill_categories, public.skills, public.assessments, public.assessment_sections, public.assessment_questions to authenticated;
grant select, update on public.candidate_profiles to authenticated;
grant select, insert, delete on public.candidate_skills to authenticated;
grant select, insert on public.skill_evidence to authenticated;
grant select, insert on public.assessment_attempts to authenticated;
grant select, insert on public.assessment_answers to authenticated;
grant select on public.assessment_results, public.skill_verifications to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant usage on schema private to authenticated;
revoke all on private.assessment_answer_keys from anon, authenticated;

-- Demo profile is isolated from real Auth users; fixture content uses a dedicated external reference.
insert into public.candidate_profiles(external_ref, display_name, is_demo)
values ('demo-candidate-001','Demo Candidate 001',true)
on conflict (external_ref) do nothing;

insert into public.skill_categories(name,slug,description,sort_order) values
('Technical Skills','technical-skills','Role-specific technical competencies',10),
('Professional Skills','professional-skills','Communication, collaboration and workplace competencies',20)
on conflict (slug) do nothing;

insert into public.skills(category_id,name,slug,description,level)
select c.id, v.name, v.slug, v.description, v.level
from (values
 ('technical-skills','SQL Fundamentals','sql-fundamentals','Relational queries, filtering and joins','intermediate'),
 ('technical-skills','API Design','api-design','REST conventions, validation and error handling','intermediate'),
 ('professional-skills','Communication','communication','Clear written and verbal communication','beginner')
) v(category_slug,name,slug,description,level)
join public.skill_categories c on c.slug=v.category_slug
on conflict (slug) do nothing;

insert into public.assessments(skill_id,title,description,passing_score,duration_minutes,max_attempts,retake_cooldown_hours,is_published)
select s.id,'SQL Fundamentals — Demo Assessment','Seed assessment for local integration tests.',70,20,3,0,true
from public.skills s where s.slug='sql-fundamentals'
and not exists(select 1 from public.assessments a where a.skill_id=s.id and a.title='SQL Fundamentals — Demo Assessment');

insert into public.assessment_sections(assessment_id,title,sort_order)
select a.id,'Core Concepts',1 from public.assessments a
where a.title='SQL Fundamentals — Demo Assessment'
and not exists(select 1 from public.assessment_sections sec where sec.assessment_id=a.id);

insert into public.assessment_questions(section_id,question_type,prompt,options,points,sort_order)
select sec.id,'single_choice','Which SQL clause filters rows before grouping?',
'[{"id":"a","text":"HAVING"},{"id":"b","text":"WHERE"},{"id":"c","text":"ORDER BY"},{"id":"d","text":"LIMIT"}]'::jsonb,1,1
from public.assessment_sections sec
join public.assessments a on a.id=sec.assessment_id
where a.title='SQL Fundamentals — Demo Assessment'
and not exists(select 1 from public.assessment_questions q where q.section_id=sec.id);

insert into private.assessment_answer_keys(question_id,correct_answers)
select q.id, '"b"'::jsonb from public.assessment_questions q
join public.assessment_sections sec on sec.id=q.section_id
join public.assessments a on a.id=sec.assessment_id
where a.title='SQL Fundamentals — Demo Assessment'
on conflict (question_id) do nothing;




-- =============================================================
-- SOURCE MIGRATION 2/11: supabase/migrations/20261104160000_assessment_security_hardening.sql
-- =============================================================

-- Follow-up hardening for verified skills assessments.
drop policy if exists "own candidate skills delete" on public.candidate_skills;
create policy "own unused candidate skills delete" on public.candidate_skills
for delete to authenticated
using (
  exists (select 1 from public.candidate_profiles cp where cp.id=candidate_id and cp.auth_user_id=(select auth.uid()))
  and not exists (select 1 from public.assessment_attempts a where a.candidate_skill_id=id)
);

create policy "own active answers update" on public.assessment_answers
for update to authenticated
using (
  exists (select 1 from public.assessment_attempts a join public.candidate_profiles cp on cp.id=a.candidate_id
          where a.id=attempt_id and a.status='in_progress' and a.expires_at>now() and cp.auth_user_id=(select auth.uid()))
)
with check (
  exists (select 1 from public.assessment_attempts a join public.candidate_profiles cp on cp.id=a.candidate_id
          where a.id=attempt_id and a.status='in_progress' and a.expires_at>now() and cp.auth_user_id=(select auth.uid()))
);
grant update on public.assessment_answers to authenticated;

create index if not exists idx_candidate_skills_skill_id on public.candidate_skills(skill_id);
create index if not exists idx_skill_evidence_candidate_skill on public.skill_evidence(candidate_skill_id);
create index if not exists idx_assessment_sections_assessment_id on public.assessment_sections(assessment_id);
create index if not exists idx_assessment_questions_section_id on public.assessment_questions(section_id);
create index if not exists idx_assessment_attempts_assessment_id on public.assessment_attempts(assessment_id);
create index if not exists idx_assessment_attempts_candidate_skill_id on public.assessment_attempts(candidate_skill_id);
create index if not exists idx_assessment_answers_question_id on public.assessment_answers(question_id);




-- =============================================================
-- SOURCE MIGRATION 3/11: supabase/migrations/20261104170000_restrict_privileged_rpc_execution.sql
-- =============================================================

-- Keep privileged routines inaccessible to direct client RPC calls.
create or replace function public.ensure_candidate_profile()
returns uuid language sql security definer set search_path = ''
as $function$ select private.ensure_candidate_profile(); $function$;
revoke all on function private.ensure_candidate_profile() from public, anon, authenticated;
revoke all on function public.ensure_candidate_profile() from public, anon;
grant execute on function public.ensure_candidate_profile() to authenticated;

create or replace function public.submit_assessment_attempt(p_attempt_id uuid)
returns jsonb language sql security definer set search_path = ''
as $function$ select private.submit_assessment_attempt(p_attempt_id); $function$;
revoke all on function private.submit_assessment_attempt(uuid) from public, anon, authenticated;
revoke all on function public.submit_assessment_attempt(uuid) from public, anon;
grant execute on function public.submit_assessment_attempt(uuid) to authenticated;




-- =============================================================
-- SOURCE MIGRATION 4/11: supabase/migrations/20261104180000_seed_demo_candidate_skill.sql
-- =============================================================

-- Attach the demo candidate to the seeded SQL Fundamentals skill.
insert into public.candidate_skills(candidate_id,skill_id,status)
select cp.id,s.id,'claimed'
from public.candidate_profiles cp
cross join public.skills s
where cp.external_ref='demo-candidate-001' and s.slug='sql-fundamentals'
on conflict (candidate_id,skill_id) do nothing;




-- =============================================================
-- SOURCE MIGRATION 5/11: supabase/migrations/20261104190000_verified_skills_engine_hardening.sql
-- =============================================================

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




-- =============================================================
-- SOURCE MIGRATION 6/11: supabase/migrations/20261104190100_enforce_server_owned_assessment_workflow.sql
-- =============================================================

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




-- =============================================================
-- SOURCE MIGRATION 7/11: supabase/migrations/20261104200000_verified_skills_integrity_concurrency.sql
-- =============================================================

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




-- =============================================================
-- SOURCE MIGRATION 8/11: supabase/migrations/20261104200200_finalize_scoring_and_profile_permissions.sql
-- =============================================================

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




-- =============================================================
-- SOURCE MIGRATION 9/11: supabase/migrations/20261104210000_index_attempts_candidate_skill_owner.sql
-- =============================================================

create index if not exists idx_attempts_candidate_skill_owner
  on public.assessment_attempts(candidate_skill_id, candidate_id);




-- =============================================================
-- SOURCE MIGRATION 10/11: supabase/migrations/20261104220000_fix_candidate_profile_bootstrap_wrapper.sql
-- =============================================================

-- The profile bootstrap wrapper must execute with its owner privileges.
-- The private implementation is intentionally not directly executable by clients.
create or replace function public.ensure_candidate_profile()
returns uuid
language sql
security definer
set search_path = ''
as $function$
  select private.ensure_candidate_profile();
$function$;

revoke all on function public.ensure_candidate_profile() from public, anon;
grant execute on function public.ensure_candidate_profile() to authenticated;




-- =============================================================
-- SOURCE MIGRATION 11/11: supabase/migrations/20261104230000_guard_candidate_skill_removal.sql
-- =============================================================

-- Candidate skill removal must not cascade-delete assessment history.
revoke delete on public.candidate_skills from anon, authenticated;

create or replace function private.remove_candidate_skill(p_candidate_skill_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_candidate_skill public.candidate_skills%rowtype;
begin
  if v_user is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  select cs.* into v_candidate_skill
  from public.candidate_skills cs
  join public.candidate_profiles cp on cp.id=cs.candidate_id
  where cs.id=p_candidate_skill_id and cp.auth_user_id=v_user
  for update of cs;

  if not found then
    raise exception 'Candidate skill not found' using errcode='P0002';
  end if;

  if v_candidate_skill.status <> 'claimed' or exists (
    select 1 from public.assessment_attempts aa
    where aa.candidate_skill_id=p_candidate_skill_id
  ) then
    raise exception 'A skill claim with assessment history cannot be removed' using errcode='P0001';
  end if;

  delete from public.candidate_skills where id=p_candidate_skill_id;
  return jsonb_build_object('deleted',true,'id',p_candidate_skill_id);
end;
$function$;
revoke all on function private.remove_candidate_skill(uuid) from public,anon,authenticated;

create or replace function public.remove_candidate_skill(p_candidate_skill_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select private.remove_candidate_skill(p_candidate_skill_id);
$function$;
revoke all on function public.remove_candidate_skill(uuid) from public,anon;
grant execute on function public.remove_candidate_skill(uuid) to authenticated;


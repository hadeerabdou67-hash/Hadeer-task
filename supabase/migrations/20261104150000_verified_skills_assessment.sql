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
create or replace function public.ensure_candidate_profile()
returns uuid language plpgsql security invoker set search_path = ''
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  insert into public.candidate_profiles(auth_user_id)
  values (auth.uid())
  on conflict (auth_user_id) do update set auth_user_id = excluded.auth_user_id
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.ensure_candidate_profile() from public, anon;
grant execute on function public.ensure_candidate_profile() to authenticated;

-- Submit and score atomically inside Postgres. Answer keys are never selected by API queries.
create or replace function public.submit_assessment_attempt(p_attempt_id uuid)
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
           (select coalesce(array_agg(x order by x), array[]::text[]) from jsonb_array_elements_text(aa.answer) x)
           =
           (select coalesce(array_agg(x order by x), array[]::text[]) from jsonb_array_elements_text(k.correct_answers) x))
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

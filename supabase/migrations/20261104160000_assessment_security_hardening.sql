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

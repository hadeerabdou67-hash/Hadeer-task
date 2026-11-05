create index if not exists idx_attempts_candidate_skill_owner
  on public.assessment_attempts(candidate_skill_id, candidate_id);

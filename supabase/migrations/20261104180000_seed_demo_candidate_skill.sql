-- Attach the demo candidate to the seeded SQL Fundamentals skill.
insert into public.candidate_skills(candidate_id,skill_id,status)
select cp.id,s.id,'claimed'
from public.candidate_profiles cp
cross join public.skills s
where cp.external_ref='demo-candidate-001' and s.slug='sql-fundamentals'
on conflict (candidate_id,skill_id) do nothing;

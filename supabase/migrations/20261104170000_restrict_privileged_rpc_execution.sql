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

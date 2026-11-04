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

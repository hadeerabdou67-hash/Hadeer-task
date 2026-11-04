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

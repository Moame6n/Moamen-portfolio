-- Do not expose or rejoin rooms after they have finished.
create or replace function public.get_private_battle(p_invite_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_match public.private_battle_matches%rowtype;
begin
  select * into v_match
  from public.private_battle_matches
  where invite_code = upper(btrim(p_invite_code))
    and expires_at > now()
    and status in ('waiting', 'ready', 'active')
  limit 1;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'match_id', v_match.id,
    'invite_code', v_match.invite_code,
    'host_name', v_match.host_name,
    'guest_name', v_match.guest_name,
    'category', v_match.category,
    'status', v_match.status,
    'questions', case when v_match.status = 'active' then coalesce(v_match.questions, '[]'::jsonb) else null end,
    'expires_at', v_match.expires_at
  );
end;
$$;
revoke all on function public.get_private_battle(text) from public;
grant execute on function public.get_private_battle(text) to anon, authenticated;

create or replace function public.join_private_battle(
  p_invite_code text,
  p_guest_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_match public.private_battle_matches%rowtype;
  v_guest_name text := btrim(p_guest_name);
begin
  if v_guest_name is null or length(v_guest_name) < 1 or length(v_guest_name) > 160 then
    raise exception 'invalid guest name';
  end if;

  select * into v_match
  from public.private_battle_matches
  where invite_code = upper(btrim(p_invite_code))
    and expires_at > now()
    and status in ('waiting', 'ready', 'active')
  for update;

  if not found then
    raise exception 'private match not found, expired, or finished';
  end if;

  if v_match.guest_name is null and v_match.status = 'waiting' then
    update public.private_battle_matches
    set guest_name = v_guest_name, status = 'ready', updated_at = now()
    where id = v_match.id
    returning * into v_match;
  elsif v_match.guest_name is distinct from v_guest_name then
    raise exception 'private match already has a guest';
  end if;

  return jsonb_build_object(
    'match_id', v_match.id,
    'invite_code', v_match.invite_code,
    'host_name', v_match.host_name,
    'guest_name', v_match.guest_name,
    'category', v_match.category,
    'status', v_match.status,
    'questions', case when v_match.status = 'active' then coalesce(v_match.questions, '[]'::jsonb) else null end,
    'expires_at', v_match.expires_at
  );
end;
$$;
revoke all on function public.join_private_battle(text,text) from public;
grant execute on function public.join_private_battle(text,text) to anon, authenticated;


create or replace function public.finish_private_battle(p_invite_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.private_battle_matches
  set status = 'finished', updated_at = now()
  where invite_code = upper(btrim(p_invite_code))
    and status in ('waiting', 'ready', 'active');
  return found;
end;
$$;
revoke all on function public.finish_private_battle(text) from public;
grant execute on function public.finish_private_battle(text) to anon, authenticated;

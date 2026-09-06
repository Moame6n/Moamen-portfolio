-- Secure Battle result writes behind an authenticated/anonymous RPC.
-- The server derives user_id and is_win; the browser cannot choose either value.
create or replace function public.save_battle_result(
  p_match_id uuid,
  p_player_name text,
  p_opponent_name text,
  p_player_correct integer,
  p_opponent_correct integer,
  p_player_time_seconds numeric default null,
  p_opponent_time_seconds numeric default null,
  p_vs_bot boolean default false,
  p_category text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_win boolean;
  v_result_id uuid;
begin
  if p_match_id is null then raise exception 'match_id is required'; end if;
  if p_player_name is null or length(btrim(p_player_name)) < 1 or length(p_player_name) > 160 then
    raise exception 'invalid player name';
  end if;
  if p_opponent_name is null or length(btrim(p_opponent_name)) < 1 or length(p_opponent_name) > 160 then
    raise exception 'invalid opponent name';
  end if;
  if p_player_correct is null or p_player_correct < 0 or p_player_correct > 10 then
    raise exception 'invalid player score';
  end if;
  if p_opponent_correct is null or p_opponent_correct < 0 or p_opponent_correct > 10 then
    raise exception 'invalid opponent score';
  end if;
  if p_player_time_seconds is not null and (p_player_time_seconds < 0 or p_player_time_seconds > 180) then
    raise exception 'invalid player time';
  end if;
  if p_opponent_time_seconds is not null and (p_opponent_time_seconds < 0 or p_opponent_time_seconds > 180) then
    raise exception 'invalid opponent time';
  end if;
  if p_category is not null and length(p_category) > 80 then
    raise exception 'invalid category';
  end if;

  -- Authenticated players can submit a match only once. Anonymous play remains supported.
  if v_user_id is not null and exists (
    select 1 from public.battle_results
    where match_id = p_match_id and user_id = v_user_id
  ) then
    select id into v_result_id from public.battle_results
    where match_id = p_match_id and user_id = v_user_id
    order by created_at desc limit 1;
    return v_result_id;
  end if;

  v_is_win := case
    when p_player_correct <> p_opponent_correct then p_player_correct > p_opponent_correct
    else coalesce(p_player_time_seconds, 180) <= coalesce(p_opponent_time_seconds, 180)
  end;

  insert into public.battle_results (
    match_id, player_name, opponent_name, player_correct, opponent_correct,
    player_time_seconds, is_win, vs_bot, category, user_id
  ) values (
    p_match_id, btrim(p_player_name), btrim(p_opponent_name), p_player_correct, p_opponent_correct,
    p_player_time_seconds, v_is_win, coalesce(p_vs_bot, false), nullif(btrim(p_category), ''), v_user_id
  ) returning id into v_result_id;

  return v_result_id;
end;
$$;

revoke all on function public.save_battle_result(uuid,text,text,integer,integer,numeric,numeric,boolean,text) from public;
grant execute on function public.save_battle_result(uuid,text,text,integer,integer,numeric,numeric,boolean,text) to anon, authenticated;
revoke insert on public.battle_results from anon, authenticated;

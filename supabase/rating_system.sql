-- Secure rating system for authenticated human-vs-human battles.
-- Anonymous and bot games remain supported but do not change a user's rating.
-- All rating mutations happen inside save_battle_result in one transaction.

create table if not exists public.battle_ratings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  rating_points integer not null default 1000,
  matches_played integer not null default 0,
  wins integer not null default 0,
  losses integer not null default 0,
  draws integer not null default 0,
  win_streak integer not null default 0,
  best_win_streak integer not null default 0,
  updated_at timestamptz not null default now(),
  constraint battle_ratings_points_check check (rating_points between 100 and 3000),
  constraint battle_ratings_nonnegative_check check (matches_played >= 0 and wins >= 0 and losses >= 0 and draws >= 0 and win_streak >= 0 and best_win_streak >= 0)
);

alter table public.battle_ratings enable row level security;
revoke all on public.battle_ratings from anon, authenticated;
grant select on public.battle_ratings to authenticated;
drop policy if exists "battle ratings owner select" on public.battle_ratings;
create policy "battle ratings owner select" on public.battle_ratings for select to authenticated using (user_id = auth.uid());

alter table public.battle_results add column if not exists rating_delta integer;
alter table public.battle_results add column if not exists rating_after integer;
alter table public.battle_results add column if not exists rank_name text;

-- Keep the participant identity server-side for matchmaking matches.
alter table public.matchmaking_queue add column if not exists user_id uuid references auth.users(id) on delete set null;
create index if not exists matchmaking_queue_match_user_idx on public.matchmaking_queue(match_id, user_id);

-- Keep the participant identity server-side for private matches.
alter table public.private_battle_matches add column if not exists host_user_id uuid references auth.users(id) on delete set null;
alter table public.private_battle_matches add column if not exists guest_user_id uuid references auth.users(id) on delete set null;

create or replace function public.rating_rank(p_points integer)
returns text
language sql
immutable
as $$
  select case
    when p_points >= 2200 then 'Diamond'
    when p_points >= 1800 then 'Platinum'
    when p_points >= 1400 then 'Gold'
    when p_points >= 1100 then 'Silver'
    else 'Bronze'
  end
$$;

-- Matchmaking now stores auth.uid() when available and returns the opponent identity internally.
create or replace function public.try_match_battle(p_player_name text, p_category text)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare
  opponent record;
  new_match_id uuid;
  v_user_id uuid := auth.uid();
begin
  if p_player_name is null or length(btrim(p_player_name)) not between 1 and 160 then
    raise exception 'invalid player name';
  end if;

  select * into opponent
  from public.matchmaking_queue
  where status = 'waiting'
    and (category = p_category or p_category = 'مختلط' or category = 'مختلط')
  order by created_at asc
  limit 1
  for update skip locked;

  if found then
    new_match_id := gen_random_uuid();
    update public.matchmaking_queue
      set status = 'matched', match_id = new_match_id
      where id = opponent.id;
    insert into public.matchmaking_queue (player_name, category, match_id, status, user_id)
      values (btrim(p_player_name), p_category, new_match_id, 'matched', v_user_id);
    return jsonb_build_object('matched', true, 'match_id', new_match_id, 'opponent_name', opponent.player_name);
  else
    insert into public.matchmaking_queue (player_name, category, status, user_id)
      values (btrim(p_player_name), p_category, 'waiting', v_user_id);
    return jsonb_build_object('matched', false);
  end if;
end;
$$;

-- Private-room creation records the authenticated host without exposing it to the browser.
create or replace function public.create_private_battle(p_host_name text, p_category text default 'مختلط')
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id uuid; v_code text; v_category text := coalesce(nullif(btrim(p_category), ''), 'مختلط'); v_user_id uuid := auth.uid();
begin
  if p_host_name is null or length(btrim(p_host_name)) not between 1 and 160 then raise exception 'invalid host name'; end if;
  if length(v_category) > 80 then raise exception 'invalid category'; end if;
  v_code := public.generate_private_battle_code();
  insert into public.private_battle_matches (invite_code, host_name, category, host_user_id)
  values (v_code, btrim(p_host_name), v_category, v_user_id) returning id into v_id;
  return jsonb_build_object('match_id', v_id, 'invite_code', v_code, 'host_name', btrim(p_host_name), 'category', v_category, 'status', 'waiting');
end;
$$;
revoke all on function public.create_private_battle(text,text) from public;
grant execute on function public.create_private_battle(text,text) to anon, authenticated;

-- Private-room joining records the authenticated guest while retaining anonymous support.
create or replace function public.join_private_battle(p_invite_code text, p_guest_name text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_match public.private_battle_matches%rowtype; v_guest_name text := btrim(p_guest_name); v_user_id uuid := auth.uid();
begin
  if v_guest_name is null or length(v_guest_name) not between 1 and 160 then raise exception 'invalid guest name'; end if;
  select * into v_match from public.private_battle_matches where invite_code = upper(btrim(p_invite_code)) and expires_at > now() and status <> 'cancelled' for update;
  if not found then raise exception 'private match not found or expired'; end if;
  if v_match.guest_name is null and v_match.status = 'waiting' then
    update public.private_battle_matches set guest_name = v_guest_name, guest_user_id = v_user_id, status = 'ready', updated_at = now() where id = v_match.id returning * into v_match;
  elsif v_match.guest_name is distinct from v_guest_name then
    raise exception 'private match already has a guest';
  end if;
  return jsonb_build_object('match_id', v_match.id, 'invite_code', v_match.invite_code, 'host_name', v_match.host_name, 'guest_name', v_match.guest_name, 'category', v_match.category, 'status', v_match.status, 'questions', case when v_match.status = 'active' then coalesce(v_match.questions, '[]'::jsonb) else null end, 'expires_at', v_match.expires_at);
end;
$$;
revoke all on function public.join_private_battle(text,text) from public;
grant execute on function public.join_private_battle(text,text) to anon, authenticated;

create or replace function public.save_battle_result(
  p_match_id uuid, p_player_name text, p_opponent_name text,
  p_player_correct integer, p_opponent_correct integer,
  p_player_time_seconds numeric default null, p_opponent_time_seconds numeric default null,
  p_vs_bot boolean default false, p_category text default null
)
returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid := auth.uid(); v_is_win boolean; v_result_id uuid;
  v_opponent_id uuid; v_player_rating integer; v_opponent_rating integer := 1000;
  v_expected numeric; v_outcome numeric; v_delta integer; v_new_rating integer; v_streak integer; v_rank text;
begin
  if p_match_id is null then raise exception 'match_id is required'; end if;
  if p_player_name is null or length(btrim(p_player_name)) not between 1 and 160 then raise exception 'invalid player name'; end if;
  if p_opponent_name is null or length(btrim(p_opponent_name)) not between 1 and 160 then raise exception 'invalid opponent name'; end if;
  if p_player_correct is null or p_player_correct not between 0 and 10 then raise exception 'invalid player score'; end if;
  if p_opponent_correct is null or p_opponent_correct not between 0 and 10 then raise exception 'invalid opponent score'; end if;
  if p_player_time_seconds is not null and (p_player_time_seconds < 0 or p_player_time_seconds > 180) then raise exception 'invalid player time'; end if;
  if p_opponent_time_seconds is not null and (p_opponent_time_seconds < 0 or p_opponent_time_seconds > 180) then raise exception 'invalid opponent time'; end if;
  if p_category is not null and length(p_category) > 80 then raise exception 'invalid category'; end if;

  if v_user_id is not null and exists (select 1 from public.battle_results where match_id = p_match_id and user_id = v_user_id) then
    select id into v_result_id from public.battle_results where match_id = p_match_id and user_id = v_user_id order by created_at desc limit 1;
    return v_result_id;
  end if;

  v_is_win := case when p_player_correct <> p_opponent_correct then p_player_correct > p_opponent_correct else coalesce(p_player_time_seconds, 180) <= coalesce(p_opponent_time_seconds, 180) end;

  if v_user_id is not null and coalesce(p_vs_bot, false) = false then
    select case when q.user_id = v_user_id then q2.user_id else q.user_id end into v_opponent_id
      from public.matchmaking_queue q join public.matchmaking_queue q2 on q2.match_id = q.match_id and q2.id <> q.id
      where q.match_id = p_match_id and q.user_id = v_user_id limit 1;
    if v_opponent_id is null then
      select case when host_user_id = v_user_id then guest_user_id else host_user_id end into v_opponent_id
        from public.private_battle_matches where id = p_match_id and (host_user_id = v_user_id or guest_user_id = v_user_id) limit 1;
    end if;
    insert into public.battle_ratings(user_id) values (v_user_id) on conflict (user_id) do nothing;
    select rating_points, win_streak into v_player_rating, v_streak from public.battle_ratings where user_id = v_user_id for update;
    if v_opponent_id is not null then
      insert into public.battle_ratings(user_id) values (v_opponent_id) on conflict (user_id) do nothing;
      select rating_points into v_opponent_rating from public.battle_ratings where user_id = v_opponent_id;
    end if;
    v_expected := 1.0 / (1.0 + power(10.0, (v_opponent_rating - v_player_rating) / 400.0));
    v_outcome := case when p_player_correct = p_opponent_correct and coalesce(p_player_time_seconds,180) = coalesce(p_opponent_time_seconds,180) then 0.5 when v_is_win then 1 else 0 end;
    v_delta := greatest(-35, least(35, round(24 * (v_outcome - v_expected) + case when v_is_win then least(8, greatest(0, p_opponent_correct - p_player_correct) * 2) else 0 end + case when v_is_win and coalesce(p_player_time_seconds,180) < coalesce(p_opponent_time_seconds,180) then 3 else 0 end + case when v_streak >= 2 and v_is_win then least(6, v_streak) else 0 end))::integer);
    v_new_rating := greatest(100, least(3000, v_player_rating + v_delta));
    v_streak := case when v_is_win then v_streak + 1 else 0 end;
    v_rank := public.rating_rank(v_new_rating);
    update public.battle_ratings set rating_points=v_new_rating, matches_played=matches_played+1, wins=wins+case when v_is_win then 1 else 0 end, losses=losses+case when v_is_win then 0 else 1 end, win_streak=v_streak, best_win_streak=greatest(best_win_streak,v_streak), updated_at=now() where user_id=v_user_id;
  end if;

  insert into public.battle_results (match_id, player_name, opponent_name, player_correct, opponent_correct, player_time_seconds, is_win, vs_bot, category, user_id, rating_delta, rating_after, rank_name)
  values (p_match_id, btrim(p_player_name), btrim(p_opponent_name), p_player_correct, p_opponent_correct, p_player_time_seconds, v_is_win, coalesce(p_vs_bot,false), nullif(btrim(p_category),''), v_user_id, v_delta, v_new_rating, v_rank)
  returning id into v_result_id;
  return v_result_id;
end;
$$;
revoke all on function public.save_battle_result(uuid,text,text,integer,integer,numeric,numeric,boolean,text) from public;
grant execute on function public.save_battle_result(uuid,text,text,integer,integer,numeric,numeric,boolean,text) to anon, authenticated;

-- Leaderboard now ranks authenticated players by server-maintained rating, while preserving legacy anonymous rows.
create or replace function public.get_battle_leaderboard(p_limit integer default 10)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare result jsonb;
begin
  select coalesce(jsonb_agg(x), '[]'::jsonb) into result from (
    select coalesce(p.full_name, br.player_name) as player_name, count(*) as matches_played,
      sum(case when br.is_win then 1 else 0 end) as wins, sum(case when br.is_win then 0 else 1 end) as losses,
      round(100.0 * sum(case when br.is_win then 1 else 0 end) / count(*), 0) as win_rate,
      coalesce(r.rating_points, sum(case when br.is_win then 3 else 0 end)::integer) as points,
      coalesce(public.rating_rank(r.rating_points), 'Bronze') as rank_name
    from public.battle_results br left join public.battle_ratings r on r.user_id = br.user_id left join public.profiles p on p.id = br.user_id
    group by br.user_id, coalesce(p.full_name, br.player_name), r.rating_points
    order by points desc, win_rate desc, matches_played desc limit greatest(1, least(p_limit, 50))
  ) x;
  return result;
end;
$$;
revoke all on function public.get_battle_leaderboard(integer) from public;
grant execute on function public.get_battle_leaderboard(integer) to anon, authenticated;

-- Security checks: no direct client writes to rating state.
revoke insert, update, delete on public.battle_ratings from anon, authenticated;
revoke insert, update, delete on public.battle_results from anon, authenticated;
notify pgrst, 'reload schema';

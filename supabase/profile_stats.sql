-- Owner-scoped, read-only profile statistics. No client-supplied user id is accepted.
create or replace function public.get_my_battle_stats()
returns jsonb
language sql
security definer
set search_path = public, extensions
as 'select jsonb_build_object(
  ''authenticated'', auth.uid() is not null,
  ''summary'', (select jsonb_build_object(
    ''matches_played'', count(*)::int,
    ''wins'', coalesce(sum(case when is_win then 1 else 0 end), 0)::int,
    ''losses'', coalesce(sum(case when not is_win then 1 else 0 end), 0)::int,
    ''win_rate'', case when count(*) = 0 then 0 else round(sum(case when is_win then 1 else 0 end)::numeric / count(*) * 100, 1) end,
    ''average_accuracy'', coalesce(round(avg(player_correct::numeric / 10 * 100), 1), 0),
    ''average_time_seconds'', coalesce(round(avg(player_time_seconds), 1), 0),
    ''best_score'', coalesce(max(player_correct), 0),
    ''best_time_seconds'', min(nullif(player_time_seconds, 0))
  ) from public.battle_results where user_id = auth.uid()),
  ''rating'', (select jsonb_build_object(
    ''points'', coalesce(r.rating_points, 1000),
    ''rank_name'', public.rating_rank(coalesce(r.rating_points, 1000)),
    ''matches_played'', coalesce(r.matches_played, 0),
    ''wins'', coalesce(r.wins, 0),
    ''losses'', coalesce(r.losses, 0),
    ''win_streak'', coalesce(r.win_streak, 0),
    ''best_win_streak'', coalesce(r.best_win_streak, 0),
    ''next_rank'', case when coalesce(r.rating_points, 1000) < 1100 then ''Silver'' when r.rating_points < 1400 then ''Gold'' when r.rating_points < 1800 then ''Platinum'' when r.rating_points < 2200 then ''Diamond'' else null end,
    ''next_points'', case when coalesce(r.rating_points, 1000) < 1100 then 1100 when r.rating_points < 1400 then 1400 when r.rating_points < 1800 then 1800 when r.rating_points < 2200 then 2200 else null end,
    ''progress_percent'', case when coalesce(r.rating_points, 1000) >= 2200 then 100 else round(greatest(0, least(100, (coalesce(r.rating_points, 1000) - case when coalesce(r.rating_points, 1000) < 1100 then 1000 when r.rating_points < 1400 then 1100 when r.rating_points < 1800 then 1400 else 1800 end)::numeric / (case when coalesce(r.rating_points, 1000) < 1100 then 1100 when r.rating_points < 1400 then 1400 when r.rating_points < 1800 then 1800 else 2200 end - case when coalesce(r.rating_points, 1000) < 1100 then 1000 when r.rating_points < 1400 then 1100 when r.rating_points < 1800 then 1400 else 1800 end) * 100)), 1) end
  ) from public.battle_ratings r where r.user_id = auth.uid())
)';

create or replace function public.get_my_battle_categories()
returns jsonb language sql security definer set search_path = public, extensions
as 'select coalesce(jsonb_agg(x), ''[]''::jsonb) from (
  select jsonb_build_object(
    ''name'', coalesce(nullif(btrim(category), ''''), ''مختلط''),
    ''matches'', count(*)::int,
    ''wins'', sum(case when is_win then 1 else 0 end)::int,
    ''win_rate'', round(sum(case when is_win then 1 else 0 end)::numeric / count(*) * 100, 1),
    ''average_accuracy'', round(avg(player_correct::numeric / 10 * 100), 1),
    ''average_time_seconds'', round(avg(player_time_seconds), 1)
  ) x from public.battle_results where user_id = auth.uid()
  group by coalesce(nullif(btrim(category), ''''), ''مختلط'') order by count(*) desc limit 20
)';

create or replace function public.get_my_recent_battles()
returns jsonb language sql security definer set search_path = public, extensions
as 'select coalesce(jsonb_agg(x), ''[]''::jsonb) from (
  select jsonb_build_object(
    ''opponent_name'', opponent_name, ''is_win'', is_win,
    ''player_correct'', player_correct, ''opponent_correct'', opponent_correct,
    ''player_time_seconds'', player_time_seconds,
    ''category'', coalesce(nullif(btrim(category), ''''), ''مختلط''),
    ''vs_bot'', vs_bot, ''rating_delta'', rating_delta,
    ''rating_after'', rating_after, ''rank_name'', rank_name, ''created_at'', created_at
  ) x from public.battle_results where user_id = auth.uid()
  order by created_at desc limit 20
)';

create or replace function public.get_my_battle_badges()
returns jsonb language sql security definer set search_path = public, extensions
as 'select jsonb_build_object(
  ''first_win'', exists(select 1 from public.battle_results where user_id = auth.uid() and is_win),
  ''streak_3'', coalesce((select best_win_streak from public.battle_ratings where user_id = auth.uid()), 0) >= 3,
  ''streak_5'', coalesce((select best_win_streak from public.battle_ratings where user_id = auth.uid()), 0) >= 5,
  ''accuracy_80'', coalesce((select avg(player_correct::numeric / 10 * 100) from public.battle_results where user_id = auth.uid()), 0) >= 80,
  ''multi_category'', (select count(distinct coalesce(nullif(btrim(category), ''''), ''مختلط'')) from public.battle_results where user_id = auth.uid()) >= 3,
  ''silver_or_higher'', coalesce((select rating_points from public.battle_ratings where user_id = auth.uid()), 1000) >= 1100,
  ''gold_or_higher'', coalesce((select rating_points from public.battle_ratings where user_id = auth.uid()), 1000) >= 1400
)';

revoke all on function public.get_my_battle_stats() from public;
revoke all on function public.get_my_battle_categories() from public;
revoke all on function public.get_my_recent_battles() from public;
revoke all on function public.get_my_battle_badges() from public;
grant execute on function public.get_my_battle_stats() to authenticated;
grant execute on function public.get_my_battle_categories() to authenticated;
grant execute on function public.get_my_recent_battles() to authenticated;
grant execute on function public.get_my_battle_badges() to authenticated;

create or replace function public.get_accounting_tournament_admin_analytics(
  p_passphrase text default null,
  p_from timestamptz default (now() - interval '30 days'),
  p_to timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_from timestamptz := greatest(coalesce(p_from, now() - interval '30 days'), now() - interval '180 days');
  v_to timestamptz := least(coalesce(p_to, now()), now() + interval '1 day');
  v_total_tournaments bigint;
  v_completed_tournaments bigint;
  v_active_tournaments bigint;
  v_lobby_tournaments bigint;
  v_total_players bigint;
  v_active_players bigint;
  v_total_matches bigint;
  v_completed_matches bigint;
  v_forfeits bigint;
  v_total_answers bigint;
  v_correct_answers bigint;
  v_avg_duration numeric;
  v_categories jsonb;
  v_daily jsonb;
  v_recent jsonb;
  v_active_rooms jsonb;
begin
  if not public.admin_authorized(p_passphrase) then
    raise exception 'invalid admin session';
  end if;
  if v_to <= v_from then raise exception 'invalid analytics range'; end if;

  select count(*) into v_total_tournaments from public.accounting_tournaments where created_at >= v_from and created_at < v_to;
  select count(*) into v_completed_tournaments from public.accounting_tournaments where created_at >= v_from and created_at < v_to and status='completed';
  select count(*) into v_active_tournaments from public.accounting_tournaments where status='active' and expires_at>now();
  select count(*) into v_lobby_tournaments from public.accounting_tournaments where status='lobby' and expires_at>now();
  select count(*) into v_total_players from public.accounting_tournament_players p join public.accounting_tournaments t on t.id=p.tournament_id where t.created_at >= v_from and t.created_at < v_to;
  select count(*) into v_active_players from public.accounting_tournament_players p join public.accounting_tournaments t on t.id=p.tournament_id where t.status='active' and p.presence='connected' and p.last_seen_at >= now()-interval '15 seconds';
  select count(*) into v_total_matches from public.accounting_tournament_matches m join public.accounting_tournaments t on t.id=m.tournament_id where t.created_at >= v_from and t.created_at < v_to;
  select count(*) into v_completed_matches from public.accounting_tournament_matches m join public.accounting_tournaments t on t.id=m.tournament_id where t.created_at >= v_from and t.created_at < v_to and m.status='completed';
  select count(*) into v_forfeits from public.accounting_tournament_matches m join public.accounting_tournaments t on t.id=m.tournament_id where t.created_at >= v_from and t.created_at < v_to and m.forfeit_player_id is not null;
  select count(*), count(*) filter (where a.is_correct) into v_total_answers,v_correct_answers from public.accounting_tournament_answers a join public.accounting_tournament_matches m on m.id=a.match_id join public.accounting_tournaments t on t.id=m.tournament_id where t.created_at >= v_from and t.created_at < v_to;
  select coalesce(avg(extract(epoch from (m.updated_at-m.created_at))),0) into v_avg_duration from public.accounting_tournament_matches m join public.accounting_tournaments t on t.id=m.tournament_id where t.created_at >= v_from and t.created_at < v_to and m.status='completed';

  select coalesce(jsonb_agg(x order by x.category),'[]'::jsonb) into v_categories from (
    select t.category, count(*) as tournaments, count(*) filter (where t.status='completed') as completed,
      coalesce((select count(*) from public.accounting_tournament_players p join public.accounting_tournaments tp on tp.id=p.tournament_id where tp.category=t.category and tp.created_at >= v_from and tp.created_at < v_to),0) as players,
      coalesce((select count(*) from public.accounting_tournament_matches m join public.accounting_tournaments tm on tm.id=m.tournament_id where tm.category=t.category and tm.created_at >= v_from and tm.created_at < v_to and m.forfeit_player_id is not null),0) as forfeits
    from public.accounting_tournaments t where t.created_at >= v_from and t.created_at < v_to group by t.category
  ) x;

  select coalesce(jsonb_agg(x order by x.day),'[]'::jsonb) into v_daily from (
    select to_char(d.day,'YYYY-MM-DD') as day,
      (select count(*) from public.accounting_tournaments t where t.created_at >= d.day and t.created_at < d.day+interval '1 day') as tournaments,
      (select count(*) from public.accounting_tournaments t where t.created_at >= d.day and t.created_at < d.day+interval '1 day' and t.status='completed') as completed,
      (select count(*) from public.accounting_tournament_answers a join public.accounting_tournament_matches m on m.id=a.match_id join public.accounting_tournaments t on t.id=m.tournament_id where a.created_at >= d.day and a.created_at < d.day+interval '1 day') as answers
    from generate_series(date_trunc('day',v_from),date_trunc('day',v_to),interval '1 day') d(day)
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent from (
    select t.id,t.join_code,t.category,t.status,t.created_at,t.updated_at,t.expires_at,
      count(distinct p.id) as players,count(distinct m.id) as matches,count(distinct m.id) filter (where m.status='completed') as completed_matches,
      count(distinct m.id) filter (where m.forfeit_player_id is not null) as forfeits
    from public.accounting_tournaments t left join public.accounting_tournament_players p on p.tournament_id=t.id left join public.accounting_tournament_matches m on m.tournament_id=t.id
    where t.created_at >= v_from and t.created_at < v_to group by t.id order by t.created_at desc limit 40
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_active_rooms from (
    select t.join_code,t.category,t.created_at,t.expires_at,count(p.id) as players,
      count(p.id) filter (where p.presence='connected' and p.last_seen_at >= now()-interval '15 seconds') as connected_players,
      count(m.id) filter (where m.status='active') as active_matches
    from public.accounting_tournaments t left join public.accounting_tournament_players p on p.tournament_id=t.id left join public.accounting_tournament_matches m on m.tournament_id=t.id
    where t.status='active' and t.expires_at>now() group by t.id order by t.created_at desc limit 20
  ) x;

  return jsonb_build_object(
    'range',jsonb_build_object('from',v_from,'to',v_to),
    'overview',jsonb_build_object(
      'total_tournaments',v_total_tournaments,'completed_tournaments',v_completed_tournaments,'active_tournaments',v_active_tournaments,'lobby_tournaments',v_lobby_tournaments,
      'total_players',v_total_players,'active_players',v_active_players,'total_matches',v_total_matches,'completed_matches',v_completed_matches,'forfeits',v_forfeits,
      'total_answers',v_total_answers,'correct_answers',v_correct_answers,'accuracy',case when v_total_answers=0 then 0 else round(v_correct_answers::numeric*100/v_total_answers,1) end,
      'completion_rate',case when v_total_tournaments=0 then 0 else round(v_completed_tournaments::numeric*100/v_total_tournaments,1) end,
      'avg_match_duration_seconds',round(v_avg_duration,1)
    ),
    'categories',v_categories,'daily',v_daily,'recent',v_recent,'active_rooms',v_active_rooms
  );
end $$;
revoke all on function public.get_accounting_tournament_admin_analytics(text,timestamptz,timestamptz) from public;
grant execute on function public.get_accounting_tournament_admin_analytics(text,timestamptz,timestamptz) to anon, authenticated;

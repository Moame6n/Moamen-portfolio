create or replace function public.resolve_accounting_tournament_match(p_match_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_m public.accounting_tournament_matches%rowtype; v_a public.accounting_tournament_players%rowtype; v_b public.accounting_tournament_players%rowtype; v_forfeit uuid; v_winner uuid; v_now timestamptz:=clock_timestamp();
begin
  select * into v_m from public.accounting_tournament_matches where id=p_match_id for update;
  if not found or v_m.status<>'active' then return jsonb_build_object('resolved',false); end if;
  select * into v_a from public.accounting_tournament_players where id=v_m.player_a_id for update;
  select * into v_b from public.accounting_tournament_players where id=v_m.player_b_id for update;
  if v_m.deadline_at>v_now and v_a.presence<>'forfeited' and v_b.presence<>'forfeited' and (v_a.presence='finished' or v_a.last_seen_at >= v_now-interval '15 seconds') and (v_b.presence='finished' or v_b.last_seen_at >= v_now-interval '15 seconds') then return jsonb_build_object('resolved',false); end if;
  if v_a.presence='forfeited' or (v_a.presence<>'finished' and v_a.last_seen_at < v_now-interval '15 seconds' and v_m.deadline_at>v_now) then v_forfeit:=v_a.id; end if;
  if v_b.presence='forfeited' or (v_b.presence<>'finished' and v_b.last_seen_at < v_now-interval '15 seconds' and v_m.deadline_at>v_now) then v_forfeit:=coalesce(v_forfeit,v_b.id); end if;
  if v_forfeit is not null then v_winner:=case when v_forfeit=v_a.id then v_b.id else v_a.id end; update public.accounting_tournament_players set presence='forfeited',forfeited_at=coalesce(forfeited_at,v_now) where id=v_forfeit;
  else v_winner:=case when v_m.score_a>v_m.score_b then v_a.id when v_m.score_b>v_m.score_a then v_b.id when v_m.answered_a>v_m.answered_b then v_a.id when v_m.answered_b>v_m.answered_a then v_b.id when v_m.finished_at_a is not null and v_m.finished_at_b is null then v_a.id when v_m.finished_at_b is not null and v_m.finished_at_a is null then v_b.id else v_a.id end; end if;
  update public.accounting_tournament_matches set status='completed',winner_player_id=v_winner,forfeit_player_id=v_forfeit,updated_at=now() where id=v_m.id;
  update public.accounting_tournament_players set presence=case when id=v_winner then 'finished' else presence end where id in (v_a.id,v_b.id);
  perform public.advance_accounting_tournament(v_m.tournament_id);
  return jsonb_build_object('resolved',true,'winner_player_id',v_winner,'forfeit_player_id',v_forfeit);
end $$;
revoke all on function public.resolve_accounting_tournament_match(uuid) from public;

create or replace function public.heartbeat_accounting_tournament(p_code text,p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_t public.accounting_tournaments%rowtype; v_p public.accounting_tournament_players%rowtype; v_m public.accounting_tournament_matches%rowtype; v_result jsonb;
begin
  select * into v_t from public.accounting_tournaments where join_code=upper(btrim(p_code)) and expires_at>now(); if not found then raise exception 'tournament not found or expired'; end if;
  select * into v_p from public.accounting_tournament_players where tournament_id=v_t.id and token_hash=public.tournament_token_hash(p_token) for update; if not found then raise exception 'invalid tournament token'; end if;
  if v_p.presence='forfeited' then return jsonb_build_object('ok',false,'forfeited',true); end if;
  update public.accounting_tournament_players set presence=case when presence='finished' then 'finished' else 'connected' end,last_seen_at=clock_timestamp() where id=v_p.id;
  for v_m in select * from public.accounting_tournament_matches where tournament_id=v_t.id and status='active' and (player_a_id=v_p.id or player_b_id=v_p.id) loop v_result:=public.resolve_accounting_tournament_match(v_m.id); end loop;
  return jsonb_build_object('ok',true,'forfeited',false);
end $$;
revoke all on function public.heartbeat_accounting_tournament(text,text) from public;
grant execute on function public.heartbeat_accounting_tournament(text,text) to anon, authenticated;

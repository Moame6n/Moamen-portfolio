-- Tournament governance: server deadline + heartbeat based forfeits.
alter table public.accounting_tournament_players
  add column if not exists presence text not null default 'connected',
  add column if not exists last_seen_at timestamptz not null default now(),
  add column if not exists forfeited_at timestamptz,
  add constraint accounting_tournament_presence_check check (presence in ('connected','finished','forfeited'));
alter table public.accounting_tournament_matches
  add column if not exists started_at timestamptz not null default now(),
  add column if not exists deadline_at timestamptz not null default (now() + interval '3 minutes'),
  add column if not exists forfeit_player_id uuid references public.accounting_tournament_players(id) on delete set null;

create or replace function public.advance_accounting_tournament(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare v_t public.accounting_tournaments%rowtype; v_final_exists boolean; v_m1 public.accounting_tournament_matches%rowtype; v_m2 public.accounting_tournament_matches%rowtype;
begin
  perform pg_advisory_xact_lock(hashtext(p_tournament_id::text));
  select * into v_t from public.accounting_tournaments where id=p_tournament_id for update;
  if not found then return; end if;
  select exists(select 1 from public.accounting_tournament_matches where tournament_id=p_tournament_id and round='final') into v_final_exists;
  if not v_final_exists then
    select * into v_m1 from public.accounting_tournament_matches where tournament_id=p_tournament_id and round='semifinal' and match_no=1 and status='completed';
    select * into v_m2 from public.accounting_tournament_matches where tournament_id=p_tournament_id and round='semifinal' and match_no=2 and status='completed';
    if v_m1.id is not null and v_m2.id is not null then
      insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status,started_at,deadline_at)
      values(p_tournament_id,'final',1,v_m1.winner_player_id,v_m2.winner_player_id,v_t.question_ids,'active',now(),now()+interval '3 minutes');
    end if;
  else
    if exists(select 1 from public.accounting_tournament_matches where tournament_id=p_tournament_id and round='final' and status='completed') then
      update public.accounting_tournaments set status='completed',updated_at=now() where id=p_tournament_id and status<>'completed';
    end if;
  end if;
end $$;
revoke all on function public.advance_accounting_tournament(uuid) from public;

create or replace function public.resolve_accounting_tournament_match(p_match_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_m public.accounting_tournament_matches%rowtype; v_a public.accounting_tournament_players%rowtype; v_b public.accounting_tournament_players%rowtype; v_forfeit uuid; v_winner uuid; v_now timestamptz:=clock_timestamp();
begin
  select * into v_m from public.accounting_tournament_matches where id=p_match_id for update;
  if not found or v_m.status<>'active' then return jsonb_build_object('resolved',false); end if;
  select * into v_a from public.accounting_tournament_players where id=v_m.player_a_id for update;
  select * into v_b from public.accounting_tournament_players where id=v_m.player_b_id for update;
  if v_m.deadline_at>v_now and v_a.presence<>'forfeited' and v_b.presence<>'forfeited' then return jsonb_build_object('resolved',false); end if;
  if v_a.presence='forfeited' or (v_a.last_seen_at < v_now-interval '15 seconds' and v_m.deadline_at>v_now) then v_forfeit:=v_a.id; end if;
  if v_b.presence='forfeited' or (v_b.last_seen_at < v_now-interval '15 seconds' and v_m.deadline_at>v_now) then v_forfeit:=coalesce(v_forfeit,v_b.id); end if;
  if v_forfeit is not null then
    v_winner:=case when v_forfeit=v_a.id then v_b.id else v_a.id end;
    update public.accounting_tournament_players set presence='forfeited',forfeited_at=coalesce(forfeited_at,v_now) where id=v_forfeit;
  else
    v_winner:=case when v_m.score_a>v_m.score_b then v_a.id when v_m.score_b>v_m.score_a then v_b.id when v_m.answered_a>v_m.answered_b then v_a.id when v_m.answered_b>v_m.answered_a then v_b.id when v_m.finished_at_a is not null and v_m.finished_at_b is null then v_a.id when v_m.finished_at_b is not null and v_m.finished_at_a is null then v_b.id else v_a.id end;
  end if;
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
  select * into v_t from public.accounting_tournaments where join_code=upper(btrim(p_code)) and expires_at>now();
  if not found then raise exception 'tournament not found or expired'; end if;
  select * into v_p from public.accounting_tournament_players where tournament_id=v_t.id and token_hash=public.tournament_token_hash(p_token) for update;
  if not found then raise exception 'invalid tournament token'; end if;
  if v_p.presence='forfeited' then return jsonb_build_object('ok',false,'forfeited',true); end if;
  update public.accounting_tournament_players set presence='connected',last_seen_at=clock_timestamp() where id=v_p.id;
  for v_m in select * from public.accounting_tournament_matches where tournament_id=v_t.id and status='active' and (player_a_id=v_p.id or player_b_id=v_p.id) loop
    v_result:=public.resolve_accounting_tournament_match(v_m.id);
  end loop;
  return jsonb_build_object('ok',true,'forfeited',false);
end $$;
revoke all on function public.heartbeat_accounting_tournament(text,text) from public;
grant execute on function public.heartbeat_accounting_tournament(text,text) to anon, authenticated;

create or replace function public.get_accounting_tournament_state(p_code text, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_t public.accounting_tournaments%rowtype; v_me public.accounting_tournament_players%rowtype; v_matches jsonb; v_players jsonb; v_current uuid; v_my_score int:=0; v_my_answered int:=0;
begin
  select * into v_t from public.accounting_tournaments where join_code=upper(btrim(p_code)) and expires_at>now(); if not found then raise exception 'tournament not found or expired'; end if;
  select * into v_me from public.accounting_tournament_players where tournament_id=v_t.id and token_hash=public.tournament_token_hash(p_token); if not found then raise exception 'invalid tournament token'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'slot',slot,'name',display_name,'score',score,'answered_count',answered_count,'finished',finished,'presence',presence,'is_host',is_host) order by slot),'[]'::jsonb) into v_players from public.accounting_tournament_players where tournament_id=v_t.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'round',m.round,'match_no',m.match_no,'status',m.status,'player_a',pa.display_name,'player_b',pb.display_name,'presence_a',pa.presence,'presence_b',pb.presence,'score_a',m.score_a,'score_b',m.score_b,'answered_a',m.answered_a,'answered_b',m.answered_b,'deadline_at',m.deadline_at,'started_at',m.started_at,'winner_player_id',m.winner_player_id,'forfeit_player_id',m.forfeit_player_id) order by m.round,m.match_no),'[]'::jsonb) into v_matches from public.accounting_tournament_matches m left join public.accounting_tournament_players pa on pa.id=m.player_a_id left join public.accounting_tournament_players pb on pb.id=m.player_b_id where m.tournament_id=v_t.id;
  select m.id,case when m.player_a_id=v_me.id then m.score_a else m.score_b end,case when m.player_a_id=v_me.id then m.answered_a else m.answered_b end into v_current,v_my_score,v_my_answered from public.accounting_tournament_matches m where m.tournament_id=v_t.id and m.status='active' and (m.player_a_id=v_me.id or m.player_b_id=v_me.id) order by case when m.round='final' then 1 else 0 end limit 1;
  return jsonb_build_object('tournament_id',v_t.id,'join_code',v_t.join_code,'category',v_t.category,'status',v_t.status,'players',v_players,'matches',v_matches,'my_player_id',v_me.id,'my_slot',v_me.slot,'my_name',v_me.display_name,'my_presence',v_me.presence,'my_score',v_my_score,'my_answered_count',v_my_answered,'current_match_id',v_current);
end $$;
revoke all on function public.get_accounting_tournament_state(text,text) from public;
grant execute on function public.get_accounting_tournament_state(text,text) to anon, authenticated;

create or replace function public.submit_accounting_tournament_answer(p_match_id uuid, p_token text, p_question_index integer, p_selected_index integer, p_elapsed_ms integer)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_m public.accounting_tournament_matches%rowtype; v_p public.accounting_tournament_players%rowtype; v_q public.accounting_tournament_question_bank%rowtype; v_correct boolean; v_winner uuid; v_t public.accounting_tournaments%rowtype; v_my_score int; v_my_answered int; v_my_time bigint;
begin
  if p_question_index<0 or p_question_index>9 or p_selected_index<0 or p_elapsed_ms<0 or p_elapsed_ms>180000 then raise exception 'invalid answer payload'; end if;
  select * into v_m from public.accounting_tournament_matches where id=p_match_id and status='active' for update;
  if not found then raise exception 'match not active'; end if;
  if v_m.deadline_at <= clock_timestamp() then raise exception 'match time expired'; end if;
  select * into v_p from public.accounting_tournament_players where tournament_id=v_m.tournament_id and token_hash=public.tournament_token_hash(p_token) and (id=v_m.player_a_id or id=v_m.player_b_id);
  if not found then raise exception 'invalid tournament token'; end if;
  if v_p.presence='forfeited' then raise exception 'player forfeited'; end if;
  update public.accounting_tournament_players set last_seen_at=clock_timestamp(),presence=case when p_question_index=9 then 'finished' else 'connected' end where id=v_p.id;
  if v_p.id=v_m.player_a_id then v_my_answered:=v_m.answered_a; v_my_score:=v_m.score_a; v_my_time:=v_m.time_a_ms; else v_my_answered:=v_m.answered_b; v_my_score:=v_m.score_b; v_my_time:=v_m.time_b_ms; end if;
  if v_my_answered<>p_question_index then raise exception 'answer out of sequence'; end if;
  select * into v_q from public.accounting_tournament_question_bank where id=v_m.question_ids[p_question_index+1];
  if not found or p_selected_index>=jsonb_array_length(v_q.options) then raise exception 'invalid question or option'; end if;
  v_correct:=p_selected_index=v_q.correct_index;
  insert into public.accounting_tournament_answers(match_id,player_id,question_index,selected_index,is_correct,elapsed_ms) values(p_match_id,v_p.id,p_question_index,p_selected_index,v_correct,p_elapsed_ms);
  if v_p.id=v_m.player_a_id then update public.accounting_tournament_matches set score_a=score_a+case when v_correct then 1 else 0 end,answered_a=answered_a+1,time_a_ms=time_a_ms+p_elapsed_ms,finished_at_a=case when p_question_index=9 then clock_timestamp() else finished_at_a end,updated_at=now() where id=v_m.id; else update public.accounting_tournament_matches set score_b=score_b+case when v_correct then 1 else 0 end,answered_b=answered_b+1,time_b_ms=time_b_ms+p_elapsed_ms,finished_at_b=case when p_question_index=9 then clock_timestamp() else finished_at_b end,updated_at=now() where id=v_m.id; end if;
  if p_question_index=9 then
    select * into v_m from public.accounting_tournament_matches where id=p_match_id;
    if v_m.answered_a=10 and v_m.answered_b=10 then
      if v_m.score_a<>v_m.score_b then v_winner:=case when v_m.score_a>v_m.score_b then v_m.player_a_id else v_m.player_b_id end; else v_winner:=case when v_m.finished_at_a<=v_m.finished_at_b then v_m.player_a_id else v_m.player_b_id end; end if;
      update public.accounting_tournament_matches set status='completed',winner_player_id=v_winner,updated_at=now() where id=v_m.id;
      select * into v_t from public.accounting_tournaments where id=v_m.tournament_id;
      if v_m.round='semifinal' and not exists(select 1 from public.accounting_tournament_matches where tournament_id=v_m.tournament_id and round='final') and (select count(*) from public.accounting_tournament_matches where tournament_id=v_m.tournament_id and round='semifinal' and status='completed')=2 then
        insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status) select v_m.tournament_id,'final',1,m1.winner_player_id,m2.winner_player_id,v_t.question_ids,'active' from public.accounting_tournament_matches m1,public.accounting_tournament_matches m2 where m1.tournament_id=v_m.tournament_id and m2.tournament_id=v_m.tournament_id and m1.round='semifinal' and m2.round='semifinal' and m1.match_no=1 and m2.match_no=2;
      elsif v_m.round='final' then update public.accounting_tournaments set status='completed',updated_at=now() where id=v_m.tournament_id; end if;
    end if;
  end if;
  perform public.resolve_accounting_tournament_match(v_m.id);
  return jsonb_build_object('is_correct',v_correct,'correct_index',v_q.correct_index,'score',case when v_p.id=v_m.player_a_id then v_m.score_a else v_m.score_b end,'answered_count',case when v_p.id=v_m.player_a_id then v_m.answered_a else v_m.answered_b end,'finished',p_question_index=9);
end $$;
revoke all on function public.submit_accounting_tournament_answer(uuid,text,integer,integer,integer) from public;
grant execute on function public.submit_accounting_tournament_answer(uuid,text,integer,integer,integer) to anon, authenticated;

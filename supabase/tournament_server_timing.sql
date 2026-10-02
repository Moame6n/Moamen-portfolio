alter table public.accounting_tournament_matches
  add column if not exists finished_at_a timestamptz,
  add column if not exists finished_at_b timestamptz;

create or replace function public.submit_accounting_tournament_answer(p_match_id uuid, p_token text, p_question_index integer, p_selected_index integer, p_elapsed_ms integer)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_m public.accounting_tournament_matches%rowtype; v_p public.accounting_tournament_players%rowtype; v_q public.accounting_tournament_question_bank%rowtype; v_correct boolean; v_winner uuid; v_t public.accounting_tournaments%rowtype; v_my_score int; v_my_answered int; v_my_time bigint;
begin
  if p_question_index<0 or p_question_index>9 or p_selected_index<0 or p_elapsed_ms<0 or p_elapsed_ms>180000 then raise exception 'invalid answer payload'; end if;
  select * into v_m from public.accounting_tournament_matches where id=p_match_id and status='active' for update;
  if not found then raise exception 'match not active'; end if;
  select * into v_p from public.accounting_tournament_players where tournament_id=v_m.tournament_id and token_hash=public.tournament_token_hash(p_token) and (id=v_m.player_a_id or id=v_m.player_b_id);
  if not found then raise exception 'invalid tournament token'; end if;
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
  return jsonb_build_object('is_correct',v_correct,'correct_index',v_q.correct_index,'score',case when v_p.id=v_m.player_a_id then v_m.score_a else v_m.score_b end,'answered_count',case when v_p.id=v_m.player_a_id then v_m.answered_a else v_m.answered_b end,'finished',p_question_index=9);
end $$;
revoke all on function public.submit_accounting_tournament_answer(uuid,text,integer,integer,integer) from public;
grant execute on function public.submit_accounting_tournament_answer(uuid,text,integer,integer,integer) to anon, authenticated;

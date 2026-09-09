-- Final hardening for Accounting Journal Game.
-- Admin question-bank RPCs must never be callable by public roles.
revoke execute on function public.get_accounting_game_bank(text) from public, anon, authenticated;
revoke execute on function public.get_accounting_game_stats(text) from public, anon, authenticated;
revoke execute on function public.insert_accounting_game_questions_bulk(text, jsonb) from public, anon, authenticated;
revoke execute on function public.delete_accounting_game_question(text, uuid) from public, anon, authenticated;
revoke execute on function public.save_accounting_game_attempt(text, integer, integer, integer, integer, integer, text) from public, anon, authenticated;

-- Only the authenticated gameplay RPCs remain exposed.
grant execute on function public.start_accounting_game_session() to authenticated;
grant execute on function public.submit_accounting_game_answer(uuid, integer, text, text) to authenticated;

-- Keep the player state private; it is returned only through server-authoritative RPCs.
revoke execute on function public.accounting_game_refresh_player(uuid) from public, anon, authenticated;

comment on function public.get_accounting_game_bank(text) is 'Admin-only accounting game question bank RPC; no public execute privilege.';
comment on function public.get_accounting_game_stats(text) is 'Admin-only accounting game stats RPC; no public execute privilege.';
comment on function public.insert_accounting_game_questions_bulk(text,jsonb) is 'Admin-only accounting game question insert RPC; no public execute privilege.';
comment on function public.delete_accounting_game_question(text,uuid) is 'Admin-only accounting game question delete RPC; no public execute privilege.';
comment on function public.save_accounting_game_attempt(text,integer,integer,integer,integer,integer,text) is 'Legacy client-submitted attempt RPC disabled; server writes attempts.';

-- Return server state needed by the existing UI when a round is started/resumed.
create or replace function public.start_accounting_game_session()
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare uid uuid := auth.uid();
declare v_state public.accounting_game_player_state;
declare v_existing public.accounting_game_sessions;
declare v_session public.accounting_game_sessions;
declare v_private jsonb;
declare v_safe jsonb;
declare v_count integer;
begin
  if uid is null then raise exception 'login_required'; end if;
  select * into v_existing from public.accounting_game_sessions
    where user_id=uid and status='active' and expires_at > now()
    order by created_at desc limit 1 for update;
  if v_existing.id is not null then
    select * into v_state from public.accounting_game_refresh_player(uid);
    select coalesce(jsonb_agg(jsonb_build_object('scenario',x->>'scenario','options',x->'options','category',x->>'category','difficulty',x->>'difficulty') order by ord),'[]'::jsonb)
      into v_safe from jsonb_array_elements(v_existing.questions) with ordinality as t(x,ord);
    return jsonb_build_object('session_id',v_existing.id,'questions',v_safe,'current_index',v_existing.current_index,'score',v_existing.score,'correct_count',v_existing.correct_count,'hearts_spent',v_existing.hearts_spent,'hearts',v_state.hearts,'reward_points',v_state.reward_points,'best_accuracy',v_state.best_accuracy,'status',v_existing.status);
  end if;
  select * into v_state from public.accounting_game_refresh_player(uid);
  if v_state.hearts <= 0 then raise exception 'no_hearts'; end if;
  select count(*) into v_count from public.accounting_game_sessions where user_id=uid and created_at > now() - interval '1 hour';
  if v_count >= 20 then raise exception 'rate_limit'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('scenario',scenario,'debit_account',debit_account,'credit_account',credit_account,'options',options,'explanation',explanation,'category',category,'difficulty',difficulty) order by ord),'[]'::jsonb)
    into v_private from (select scenario,debit_account,credit_account,options,explanation,category,difficulty,row_number() over () as ord from public.accounting_game_questions where status='active' order by random() limit 10) q;
  if jsonb_array_length(v_private) = 0 then raise exception 'no_questions'; end if;
  insert into public.accounting_game_sessions(user_id,questions,total_questions,expires_at) values(uid,v_private,jsonb_array_length(v_private),now()+interval '30 minutes') returning * into v_session;
  select coalesce(jsonb_agg(jsonb_build_object('scenario',x->>'scenario','options',x->'options','category',x->>'category','difficulty',x->>'difficulty') order by ord),'[]'::jsonb)
    into v_safe from jsonb_array_elements(v_private) with ordinality as t(x,ord);
  return jsonb_build_object('session_id',v_session.id,'questions',v_safe,'current_index',0,'score',0,'correct_count',0,'hearts_spent',0,'hearts',v_state.hearts,'reward_points',v_state.reward_points,'best_accuracy',v_state.best_accuracy,'status','active');
end;
$$;
revoke all on function public.start_accounting_game_session() from public, anon;
grant execute on function public.start_accounting_game_session() to authenticated;

-- Ensure the answer RPC remains the only writer for gameplay outcomes.
revoke all on function public.submit_accounting_game_answer(uuid, integer, text, text) from public, anon;
grant execute on function public.submit_accounting_game_answer(uuid, integer, text, text) to authenticated;

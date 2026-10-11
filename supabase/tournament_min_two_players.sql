-- Minimum-player tournament rules: 2, 3, or 4 real players may start.
-- 2 players: direct final. 3 players: one semifinal plus a bye into the final. 4 players: normal two semifinals.

create or replace function public.start_accounting_tournament(p_code text, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_t public.accounting_tournaments%rowtype;
  v_me public.accounting_tournament_players%rowtype;
  v_ids uuid[];
  v_count integer;
  v_p3 uuid;
begin
  select * into v_t from public.accounting_tournaments
  where join_code=upper(btrim(p_code)) and expires_at>now() and status='lobby' for update;
  if not found then raise exception 'tournament not found or closed'; end if;

  select * into v_me from public.accounting_tournament_players
  where tournament_id=v_t.id and token_hash=public.tournament_token_hash(p_token) and is_host=true;
  if not found then raise exception 'only host can start tournament'; end if;

  select count(*) into v_count from public.accounting_tournament_players where tournament_id=v_t.id;
  if v_count < 2 or v_count > 4 then raise exception 'tournament requires at least two players'; end if;

  select array_agg(id order by random()) into v_ids
  from (select id from public.accounting_tournament_question_bank
        where (category=v_t.category or v_t.category='مختلط')
        order by random() limit 10) q;
  if v_ids is null or cardinality(v_ids)<>10 then raise exception 'not enough active questions for tournament'; end if;

  update public.accounting_tournaments set status='active',question_ids=v_ids,updated_at=now() where id=v_t.id;

  if v_count=2 then
    insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status,started_at,deadline_at)
    select v_t.id,'final',1,p1.id,p2.id,v_ids,'active',now(),now()+interval '3 minutes'
    from public.accounting_tournament_players p1
    join public.accounting_tournament_players p2 on p2.tournament_id=p1.tournament_id
    where p1.tournament_id=v_t.id and p1.slot=1 and p2.slot=2;
  elsif v_count=3 then
    select id into v_p3 from public.accounting_tournament_players where tournament_id=v_t.id and slot=3;
    insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status,started_at,deadline_at)
    select v_t.id,'semifinal',1,p1.id,p2.id,v_ids,'active',now(),now()+interval '3 minutes'
    from public.accounting_tournament_players p1
    join public.accounting_tournament_players p2 on p2.tournament_id=p1.tournament_id
    where p1.tournament_id=v_t.id and p1.slot=1 and p2.slot=2;
    insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status)
    values(v_t.id,'final',1,null,v_p3,v_ids,'ready');
  else
    insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status,started_at,deadline_at)
    select v_t.id,'semifinal',1,p1.id,p2.id,v_ids,'active',now(),now()+interval '3 minutes'
    from public.accounting_tournament_players p1
    join public.accounting_tournament_players p2 on p1.tournament_id=p2.tournament_id and p1.slot=1 and p2.slot=2
    where p1.tournament_id=v_t.id;
    insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status,started_at,deadline_at)
    select v_t.id,'semifinal',2,p1.id,p2.id,v_ids,'active',now(),now()+interval '3 minutes'
    from public.accounting_tournament_players p1
    join public.accounting_tournament_players p2 on p1.tournament_id=p2.tournament_id and p1.slot=3 and p2.slot=4
    where p1.tournament_id=v_t.id;
  end if;
  return jsonb_build_object('started',true,'players',v_count,'status','active');
end $$;
revoke all on function public.start_accounting_tournament(text,text) from public;
grant execute on function public.start_accounting_tournament(text,text) to anon, authenticated;

create or replace function public.advance_accounting_tournament(p_tournament_id uuid)
returns void language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_t public.accounting_tournaments%rowtype;
  v_final public.accounting_tournament_matches%rowtype;
  v_m1 public.accounting_tournament_matches%rowtype;
  v_m2 public.accounting_tournament_matches%rowtype;
  v_sem_count integer;
begin
  perform pg_advisory_xact_lock(hashtext(p_tournament_id::text));
  select * into v_t from public.accounting_tournaments where id=p_tournament_id for update;
  if not found then return; end if;

  select * into v_final from public.accounting_tournament_matches
  where tournament_id=p_tournament_id and round='final' order by match_no limit 1;
  select count(*) into v_sem_count from public.accounting_tournament_matches
  where tournament_id=p_tournament_id and round='semifinal' and status='completed';

  if v_final.id is not null then
    if v_final.status='ready' and v_final.player_a_id is null and v_sem_count>=1 then
      select * into v_m1 from public.accounting_tournament_matches
      where tournament_id=p_tournament_id and round='semifinal' and match_no=1 and status='completed';
      if v_m1.id is not null then
        update public.accounting_tournament_matches
        set player_a_id=v_m1.winner_player_id,status='active',started_at=now(),deadline_at=now()+interval '3 minutes',updated_at=now()
        where id=v_final.id;
      end if;
    elsif v_final.status='completed' then
      update public.accounting_tournaments set status='completed',updated_at=now()
      where id=p_tournament_id and status<>'completed';
    end if;
    return;
  end if;

  if v_sem_count=2 then
    select * into v_m1 from public.accounting_tournament_matches where tournament_id=p_tournament_id and round='semifinal' and match_no=1 and status='completed';
    select * into v_m2 from public.accounting_tournament_matches where tournament_id=p_tournament_id and round='semifinal' and match_no=2 and status='completed';
    if v_m1.id is not null and v_m2.id is not null then
      insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status,started_at,deadline_at)
      values(p_tournament_id,'final',1,v_m1.winner_player_id,v_m2.winner_player_id,v_t.question_ids,'active',now(),now()+interval '3 minutes');
    end if;
  end if;
end $$;
revoke all on function public.advance_accounting_tournament(uuid) from public;

-- Real-time four-player accounting tournament.
-- The browser receives public questions without correct_index; the server scores every answer.
create extension if not exists pgcrypto;

create table if not exists public.accounting_tournaments (
  id uuid primary key default gen_random_uuid(),
  join_code text not null unique,
  host_token_hash text not null,
  category text not null default 'مختلط',
  status text not null default 'lobby',
  question_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '3 hours'),
  constraint accounting_tournaments_status_check check (status in ('lobby','active','completed','cancelled')),
  constraint accounting_tournaments_category_check check (length(btrim(category)) between 1 and 80)
);

create table if not exists public.accounting_tournament_players (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.accounting_tournaments(id) on delete cascade,
  slot smallint not null,
  display_name text not null,
  token_hash text not null,
  is_host boolean not null default false,
  score integer not null default 0,
  answered_count integer not null default 0,
  total_time_ms bigint not null default 0,
  finished boolean not null default false,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(tournament_id, slot),
  unique(tournament_id, token_hash),
  constraint accounting_tournament_player_slot_check check (slot between 1 and 4),
  constraint accounting_tournament_player_name_check check (length(btrim(display_name)) between 1 and 160)
);

create table if not exists public.accounting_tournament_matches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.accounting_tournaments(id) on delete cascade,
  round text not null,
  match_no smallint not null,
  player_a_id uuid references public.accounting_tournament_players(id) on delete set null,
  player_b_id uuid references public.accounting_tournament_players(id) on delete set null,
  question_ids uuid[] not null default '{}',
  status text not null default 'ready',
  winner_player_id uuid references public.accounting_tournament_players(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(tournament_id, round, match_no),
  constraint accounting_tournament_match_round_check check (round in ('semifinal','final')),
  constraint accounting_tournament_match_status_check check (status in ('ready','active','completed'))
);

create table if not exists public.accounting_tournament_answers (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.accounting_tournament_matches(id) on delete cascade,
  player_id uuid not null references public.accounting_tournament_players(id) on delete cascade,
  question_index smallint not null,
  selected_index smallint not null,
  is_correct boolean not null,
  elapsed_ms integer not null,
  created_at timestamptz not null default now(),
  unique(match_id, player_id, question_index),
  constraint accounting_tournament_answer_index_check check (question_index between 0 and 49),
  constraint accounting_tournament_selected_index_check check (selected_index between 0 and 11),
  constraint accounting_tournament_elapsed_check check (elapsed_ms between 0 and 180000)
);

create index if not exists accounting_tournament_code_idx on public.accounting_tournaments(join_code);
create index if not exists accounting_tournament_player_token_idx on public.accounting_tournament_players(tournament_id, token_hash);
create index if not exists accounting_tournament_match_players_idx on public.accounting_tournament_matches(player_a_id, player_b_id);

alter table public.accounting_tournaments enable row level security;
alter table public.accounting_tournament_players enable row level security;
alter table public.accounting_tournament_matches enable row level security;
alter table public.accounting_tournament_answers enable row level security;
revoke all on public.accounting_tournaments from anon, authenticated;
revoke all on public.accounting_tournament_players from anon, authenticated;
revoke all on public.accounting_tournament_matches from anon, authenticated;
revoke all on public.accounting_tournament_answers from anon, authenticated;

create or replace function public.tournament_token_hash(p_token text)
returns text language sql immutable security definer set search_path = public, extensions
as $$ select encode(digest(coalesce(p_token,''), 'sha256'), 'hex') $$;
revoke all on function public.tournament_token_hash(text) from public;

create or replace function public.create_accounting_tournament(p_name text, p_category text default 'مختلط')
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_token text := encode(gen_random_bytes(24), 'hex'); v_code text; v_tid uuid; v_category text := coalesce(nullif(btrim(p_category),''),'مختلط');
begin
  if p_name is null or length(btrim(p_name)) not between 1 and 160 then raise exception 'invalid player name'; end if;
  if length(v_category) > 80 then raise exception 'invalid category'; end if;
  loop
    v_code := upper(substr(encode(gen_random_bytes(8),'hex'),1,8));
    exit when not exists(select 1 from public.accounting_tournaments where join_code=v_code);
  end loop;
  insert into public.accounting_tournaments(join_code,host_token_hash,category) values(v_code,public.tournament_token_hash(v_token),v_category) returning id into v_tid;
  insert into public.accounting_tournament_players(tournament_id,slot,display_name,token_hash,is_host) values(v_tid,1,btrim(p_name),public.tournament_token_hash(v_token),true);
  return jsonb_build_object('tournament_id',v_tid,'join_code',v_code,'token',v_token,'slot',1,'status','lobby','category',v_category);
end $$;
revoke all on function public.create_accounting_tournament(text,text) from public;
grant execute on function public.create_accounting_tournament(text,text) to anon, authenticated;

create or replace function public.join_accounting_tournament(p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_t public.accounting_tournaments%rowtype; v_token text := encode(gen_random_bytes(24),'hex'); v_slot int; v_pid uuid;
begin
  if p_name is null or length(btrim(p_name)) not between 1 and 160 then raise exception 'invalid player name'; end if;
  select * into v_t from public.accounting_tournaments where join_code=upper(btrim(p_code)) and expires_at>now() and status='lobby' for update;
  if not found then raise exception 'tournament not found or closed'; end if;
  select coalesce(max(slot),0)+1 into v_slot from public.accounting_tournament_players where tournament_id=v_t.id;
  if v_slot>4 then raise exception 'tournament is full'; end if;
  insert into public.accounting_tournament_players(tournament_id,slot,display_name,token_hash) values(v_t.id,v_slot,btrim(p_name),public.tournament_token_hash(v_token)) returning id into v_pid;
  return jsonb_build_object('tournament_id',v_t.id,'join_code',v_t.join_code,'token',v_token,'slot',v_slot,'status',v_t.status,'category',v_t.category,'player_id',v_pid);
end $$;
revoke all on function public.join_accounting_tournament(text,text) from public;
grant execute on function public.join_accounting_tournament(text,text) to anon, authenticated;

create or replace function public.get_accounting_tournament_state(p_code text, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_t public.accounting_tournaments%rowtype; v_me public.accounting_tournament_players%rowtype; v_matches jsonb; v_players jsonb; v_current uuid;
begin
  select * into v_t from public.accounting_tournaments where join_code=upper(btrim(p_code)) and expires_at>now();
  if not found then raise exception 'tournament not found or expired'; end if;
  select * into v_me from public.accounting_tournament_players where tournament_id=v_t.id and token_hash=public.tournament_token_hash(p_token);
  if not found then raise exception 'invalid tournament token'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'slot',slot,'name',display_name,'score',score,'answered_count',answered_count,'finished',finished,'is_host',is_host) order by slot),'[]'::jsonb) into v_players from public.accounting_tournament_players where tournament_id=v_t.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'round',m.round,'match_no',m.match_no,'status',m.status,'player_a',pa.display_name,'player_b',pb.display_name,'score_a',coalesce(pa.score,0),'score_b',coalesce(pb.score,0),'winner_player_id',m.winner_player_id) order by m.round,m.match_no),'[]'::jsonb) into v_matches from public.accounting_tournament_matches m left join public.accounting_tournament_players pa on pa.id=m.player_a_id left join public.accounting_tournament_players pb on pb.id=m.player_b_id where m.tournament_id=v_t.id;
  select m.id into v_current from public.accounting_tournament_matches m where m.tournament_id=v_t.id and m.status='active' and (m.player_a_id=v_me.id or m.player_b_id=v_me.id) order by case when m.round='final' then 1 else 0 end limit 1;
  return jsonb_build_object('tournament_id',v_t.id,'join_code',v_t.join_code,'category',v_t.category,'status',v_t.status,'players',v_players,'matches',v_matches,'my_player_id',v_me.id,'my_slot',v_me.slot,'my_name',v_me.display_name,'my_score',v_me.score,'my_answered_count',v_me.answered_count,'current_match_id',v_current);
end $$;
revoke all on function public.get_accounting_tournament_state(text,text) from public;
grant execute on function public.get_accounting_tournament_state(text,text) to anon, authenticated;

create or replace function public.start_accounting_tournament(p_code text, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_t public.accounting_tournaments%rowtype; v_me public.accounting_tournament_players%rowtype; v_ids uuid[];
begin
  select * into v_t from public.accounting_tournaments where join_code=upper(btrim(p_code)) and expires_at>now() for update;
  if not found then raise exception 'tournament not found or expired'; end if;
  select * into v_me from public.accounting_tournament_players where tournament_id=v_t.id and token_hash=public.tournament_token_hash(p_token) and is_host=true;
  if not found then raise exception 'only host can start tournament'; end if;
  if (select count(*) from public.accounting_tournament_players where tournament_id=v_t.id)<>4 then raise exception 'tournament requires exactly four players'; end if;
  if v_t.status<>'lobby' then return jsonb_build_object('status',v_t.status); end if;
  select array_agg(id order by random()) into v_ids from (select id from public.battle_questions where status='active' and (category=v_t.category or v_t.category='مختلط') order by random() limit 10) q;
  if v_ids is null or cardinality(v_ids)<>10 then raise exception 'not enough active questions for tournament'; end if;
  update public.accounting_tournaments set status='active',question_ids=v_ids,updated_at=now() where id=v_t.id;
  insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status)
  select v_t.id,'semifinal',1,p1.id,p2.id,v_ids,'active' from public.accounting_tournament_players p1 join public.accounting_tournament_players p2 on p1.tournament_id=p2.tournament_id and p1.slot=1 and p2.slot=2;
  insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status)
  select v_t.id,'semifinal',2,p1.id,p2.id,v_ids,'active' from public.accounting_tournament_players p1 join public.accounting_tournament_players p2 on p1.tournament_id=p2.tournament_id and p1.slot=3 and p2.slot=4;
  return jsonb_build_object('status','active','question_count',10);
end $$;
revoke all on function public.start_accounting_tournament(text,text) from public;
grant execute on function public.start_accounting_tournament(text,text) to anon, authenticated;

create or replace function public.get_accounting_tournament_questions(p_match_id uuid, p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_m public.accounting_tournament_matches%rowtype; v_p public.accounting_tournament_players%rowtype; v_result jsonb;
begin
  select * into v_m from public.accounting_tournament_matches where id=p_match_id and status='active';
  if not found then raise exception 'match not active'; end if;
  select * into v_p from public.accounting_tournament_players where tournament_id=v_m.tournament_id and token_hash=public.tournament_token_hash(p_token) and (id=v_m.player_a_id or id=v_m.player_b_id);
  if not found then raise exception 'invalid tournament token'; end if;
  select coalesce(jsonb_agg(q order by array_position(v_m.question_ids,q.id)),'[]'::jsonb) into v_result from (select id,category,question,options,difficulty from public.battle_questions where id=any(v_m.question_ids)) q;
  return v_result;
end $$;
revoke all on function public.get_accounting_tournament_questions(uuid,text) from public;
grant execute on function public.get_accounting_tournament_questions(uuid,text) to anon, authenticated;

create or replace function public.submit_accounting_tournament_answer(p_match_id uuid, p_token text, p_question_index integer, p_selected_index integer, p_elapsed_ms integer)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare v_m public.accounting_tournament_matches%rowtype; v_p public.accounting_tournament_players%rowtype; v_q public.battle_questions%rowtype; v_correct boolean; v_winner uuid; v_other_finished boolean; v_final_id uuid; v_t public.accounting_tournaments%rowtype;
begin
  if p_question_index<0 or p_question_index>9 or p_selected_index<0 or p_elapsed_ms<0 or p_elapsed_ms>180000 then raise exception 'invalid answer payload'; end if;
  select * into v_m from public.accounting_tournament_matches where id=p_match_id and status='active' for update;
  if not found then raise exception 'match not active'; end if;
  select * into v_p from public.accounting_tournament_players where tournament_id=v_m.tournament_id and token_hash=public.tournament_token_hash(p_token) and (id=v_m.player_a_id or id=v_m.player_b_id) for update;
  if not found then raise exception 'invalid tournament token'; end if;
  if v_p.answered_count<>p_question_index then raise exception 'answer out of sequence'; end if;
  select * into v_q from public.battle_questions where id=v_m.question_ids[p_question_index+1];
  if not found or p_selected_index>=jsonb_array_length(v_q.options) then raise exception 'invalid question or option'; end if;
  v_correct := p_selected_index=v_q.correct_index;
  insert into public.accounting_tournament_answers(match_id,player_id,question_index,selected_index,is_correct,elapsed_ms) values(p_match_id,v_p.id,p_question_index,p_selected_index,v_correct,p_elapsed_ms);
  update public.accounting_tournament_players set score=score+case when v_correct then 1 else 0 end,answered_count=answered_count+1,total_time_ms=total_time_ms+p_elapsed_ms,finished=(p_question_index=9),updated_at=now() where id=v_p.id;
  if p_question_index=9 then
    if v_m.player_a_id is not null and v_m.player_b_id is not null and (select finished from public.accounting_tournament_players where id=v_m.player_a_id) and (select finished from public.accounting_tournament_players where id=v_m.player_b_id) then
      if (select score from public.accounting_tournament_players where id=v_m.player_a_id)<>(select score from public.accounting_tournament_players where id=v_m.player_b_id) then
        select case when pa.score>pb.score then pa.id else pb.id end into v_winner from public.accounting_tournament_players pa, public.accounting_tournament_players pb where pa.id=v_m.player_a_id and pb.id=v_m.player_b_id;
      else
        select case when pa.total_time_ms<=pb.total_time_ms then pa.id else pb.id end into v_winner from public.accounting_tournament_players pa, public.accounting_tournament_players pb where pa.id=v_m.player_a_id and pb.id=v_m.player_b_id;
      end if;
      update public.accounting_tournament_matches set status='completed',winner_player_id=v_winner,updated_at=now() where id=v_m.id;
      select * into v_t from public.accounting_tournaments where id=v_m.tournament_id;
      if v_m.round='semifinal' and not exists(select 1 from public.accounting_tournament_matches where tournament_id=v_m.tournament_id and round='final') and (select count(*) from public.accounting_tournament_matches where tournament_id=v_m.tournament_id and round='semifinal' and status='completed')=2 then
        insert into public.accounting_tournament_matches(tournament_id,round,match_no,player_a_id,player_b_id,question_ids,status) select v_m.tournament_id,'final',1,m1.winner_player_id,m2.winner_player_id,v_t.question_ids,'active' from public.accounting_tournament_matches m1, public.accounting_tournament_matches m2 where m1.tournament_id=v_m.tournament_id and m2.tournament_id=v_m.tournament_id and m1.round='semifinal' and m2.round='semifinal' and m1.match_no=1 and m2.match_no=2;
      elsif v_m.round='final' then
        update public.accounting_tournaments set status='completed',updated_at=now() where id=v_m.tournament_id;
      end if;
    end if;
  end if;
  return jsonb_build_object('is_correct',v_correct,'correct_index',v_q.correct_index,'score',v_p.score+case when v_correct then 1 else 0 end,'answered_count',v_p.answered_count+1,'finished',p_question_index=9);
end $$;
revoke all on function public.submit_accounting_tournament_answer(uuid,text,integer,integer,integer) from public;
grant execute on function public.submit_accounting_tournament_answer(uuid,text,integer,integer,integer) to anon, authenticated;

-- Server-authoritative hardening for Accounting Journal Game.
-- The browser receives questions without answers; Supabase computes every result.

create table if not exists public.accounting_game_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  questions jsonb not null,
  current_index integer not null default 0 check (current_index >= 0),
  score integer not null default 0 check (score >= 0),
  correct_count integer not null default 0 check (correct_count >= 0),
  total_questions integer not null check (total_questions between 1 and 20),
  hearts_spent integer not null default 0 check (hearts_spent >= 0),
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_action_at timestamptz not null default now(),
  status text not null default 'active' check (status in ('active','finished','expired','abandoned')),
  finished_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.accounting_game_player_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  hearts integer not null default 5 check (hearts between 0 and 5),
  hearts_updated_at timestamptz not null default now(),
  reward_points integer not null default 0 check (reward_points >= 0),
  best_accuracy numeric(5,2) not null default 0 check (best_accuracy between 0 and 100),
  updated_at timestamptz not null default now()
);

alter table public.accounting_game_sessions enable row level security;
alter table public.accounting_game_player_state enable row level security;
revoke all on public.accounting_game_sessions from anon, authenticated;
revoke all on public.accounting_game_player_state from anon, authenticated;
revoke all on public.accounting_game_attempts from anon, authenticated;

create unique index if not exists accounting_game_attempts_session_uidx
  on public.accounting_game_attempts(user_id, session_id)
  where session_id is not null;

-- The old client-submitted score endpoint is intentionally disabled.
revoke all on function public.save_accounting_game_attempt(text,integer,integer,integer,integer,integer,text) from anon, authenticated;

-- The legacy question endpoint no longer exposes debit/credit answers.
create or replace function public.get_accounting_game_questions(
  p_limit integer default 10, p_category text default null, p_difficulty text default null
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if p_limit is null or p_limit < 1 or p_limit > 20 then p_limit := 10; end if;
  select coalesce(jsonb_agg(row_to_json(q)), '[]'::jsonb) into result
  from (
    select id, scenario, options, category, difficulty
    from public.accounting_game_questions
    where status = 'active'
      and (p_category is null or category = p_category)
      and (p_difficulty is null or difficulty = p_difficulty)
    order by random() limit p_limit
  ) q;
  return result;
end;
$$;

create or replace function public.accounting_game_refresh_player(p_user_id uuid)
returns public.accounting_game_player_state
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.accounting_game_player_state;
declare v_add integer;
begin
  insert into public.accounting_game_player_state(user_id)
  values(p_user_id) on conflict (user_id) do nothing;
  select * into s from public.accounting_game_player_state where user_id = p_user_id for update;
  v_add := floor(extract(epoch from (now() - s.hearts_updated_at)) / 3600)::integer;
  if v_add > 0 and s.hearts < 5 then
    s.hearts := least(5, s.hearts + v_add);
    s.hearts_updated_at := case when s.hearts = 5 then now() else s.hearts_updated_at + (v_add * interval '1 hour') end;
    update public.accounting_game_player_state set hearts=s.hearts, hearts_updated_at=s.hearts_updated_at, updated_at=now() where user_id=p_user_id;
  end if;
  return s;
end;
$$;

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
    return jsonb_build_object('session_id',v_existing.id,'questions',v_safe,'current_index',v_existing.current_index,'score',v_existing.score,'correct_count',v_existing.correct_count,'hearts_spent',v_existing.hearts_spent,'hearts',v_state.hearts,'status',v_existing.status);
  end if;

  select * into v_state from public.accounting_game_refresh_player(uid);
  if v_state.hearts <= 0 then raise exception 'no_hearts'; end if;
  select count(*) into v_count from public.accounting_game_sessions where user_id=uid and created_at > now() - interval '1 hour';
  if v_count >= 20 then raise exception 'rate_limit'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('scenario',scenario,'debit_account',debit_account,'credit_account',credit_account,'options',options,'explanation',explanation,'category',category,'difficulty',difficulty) order by ord),'[]'::jsonb)
    into v_private
  from (
    select scenario,debit_account,credit_account,options,explanation,category,difficulty,row_number() over () as ord
    from public.accounting_game_questions where status='active' order by random() limit 10
  ) q;
  if jsonb_array_length(v_private) = 0 then raise exception 'no_questions'; end if;

  insert into public.accounting_game_sessions(user_id,questions,total_questions,expires_at)
  values(uid,v_private,jsonb_array_length(v_private),now()+interval '30 minutes') returning * into v_session;
  select coalesce(jsonb_agg(jsonb_build_object('scenario',x->>'scenario','options',x->'options','category',x->>'category','difficulty',x->>'difficulty') order by ord),'[]'::jsonb)
    into v_safe from jsonb_array_elements(v_private) with ordinality as t(x,ord);
  return jsonb_build_object('session_id',v_session.id,'questions',v_safe,'current_index',0,'score',0,'correct_count',0,'hearts_spent',0,'hearts',v_state.hearts,'status','active');
end;
$$;

create or replace function public.submit_accounting_game_answer(
  p_session_id uuid, p_question_index integer, p_debit text, p_credit text
)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare uid uuid := auth.uid();
declare s public.accounting_game_sessions;
declare q jsonb;
declare ps public.accounting_game_player_state;
declare is_correct boolean;
declare bonus integer := 0;
declare v_accuracy numeric;
declare v_reward integer;
declare v_status text := 'active';
begin
  if uid is null then raise exception 'login_required'; end if;
  select * into s from public.accounting_game_sessions where id=p_session_id and user_id=uid for update;
  if s.id is null then raise exception 'invalid_session'; end if;
  if s.status <> 'active' then raise exception 'session_already_closed'; end if;
  if s.expires_at <= now() then update public.accounting_game_sessions set status='expired',finished_at=now() where id=s.id; raise exception 'session_expired'; end if;
  if p_question_index <> s.current_index then raise exception 'invalid_question_order'; end if;
  if p_debit is null or p_credit is null or length(p_debit)>120 or length(p_credit)>120 then raise exception 'invalid_answer'; end if;

  q := s.questions -> p_question_index;
  is_correct := btrim(p_debit) = q->>'debit_account' and btrim(p_credit) = q->>'credit_account';
  select * into ps from public.accounting_game_refresh_player(uid);
  if is_correct then
    bonus := 100 + case when s.correct_count >= 2 then 50 else 0 end;
    s.score := s.score + bonus;
    s.correct_count := s.correct_count + 1;
  else
    s.hearts_spent := s.hearts_spent + 1;
    ps.hearts := greatest(0, ps.hearts - 1);
    ps.hearts_updated_at := case when ps.hearts=0 then now() else ps.hearts_updated_at end;
    update public.accounting_game_player_state set hearts=ps.hearts, hearts_updated_at=ps.hearts_updated_at, updated_at=now() where user_id=uid;
  end if;
  s.current_index := s.current_index + 1;
  if s.current_index >= s.total_questions or ps.hearts=0 then
    v_status := 'finished';
    s.status := 'finished'; s.finished_at := now();
    v_accuracy := round((s.correct_count::numeric * 100) / greatest(1,s.total_questions),2);
    v_reward := s.score + 100;
    update public.accounting_game_player_state set reward_points=reward_points+v_reward,best_accuracy=greatest(best_accuracy,v_accuracy),updated_at=now() where user_id=uid;
    insert into public.accounting_game_attempts(user_id,session_id,score,correct_count,total_questions,hearts_spent,reward_points,category)
    values(uid,s.id::text,s.score,s.correct_count,s.total_questions,s.hearts_spent,v_reward,'محاسبة مالية')
    on conflict (user_id,session_id) do nothing;
  end if;
  update public.accounting_game_sessions set current_index=s.current_index,score=s.score,correct_count=s.correct_count,hearts_spent=s.hearts_spent,status=s.status,finished_at=s.finished_at,last_action_at=now() where id=s.id;
  return jsonb_build_object('correct',is_correct,'score',s.score,'correct_count',s.correct_count,'current_index',s.current_index,'hearts',ps.hearts,'hearts_spent',s.hearts_spent,'finished',v_status<>'active','reward_points',coalesce(v_reward,0),'explanation',q->>'explanation','status',v_status);
end;
$$;

revoke all on function public.get_accounting_game_questions(integer,text,text) from anon, authenticated;
revoke all on function public.accounting_game_refresh_player(uuid) from public, anon, authenticated;
revoke all on function public.start_accounting_game_session() from public, anon;
revoke all on function public.submit_accounting_game_answer(uuid,integer,text,text) from public, anon;
grant execute on function public.get_accounting_game_questions(integer,text,text) to anon, authenticated;
grant execute on function public.start_accounting_game_session() to authenticated;
grant execute on function public.submit_accounting_game_answer(uuid,integer,text,text) to authenticated;

comment on table public.accounting_game_sessions is 'Server-authoritative private game sessions. Answers never leave this table.';
comment on table public.accounting_game_player_state is 'Server-authoritative hearts and rewards for the accounting game.';

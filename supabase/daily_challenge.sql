-- Daily challenge attempts, rewards, and leaderboard are owner-scoped and server-calculated.
create table if not exists public.daily_challenge_attempts (
  id uuid primary key default gen_random_uuid(),
  challenge_date date not null references public.daily_challenges(challenge_date) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  correct_answers integer not null,
  total_questions integer not null,
  time_seconds numeric not null,
  score integer not null,
  reward_points integer not null,
  streak_days integer not null default 1,
  answers jsonb not null,
  completed_at timestamptz not null default now(),
  unique (challenge_date, user_id),
  constraint daily_attempt_score_check check (correct_answers between 0 and total_questions and total_questions between 1 and 50 and time_seconds between 0 and 1800 and score >= 0 and reward_points >= 0 and streak_days >= 1)
);
create index if not exists daily_attempts_rank_idx on public.daily_challenge_attempts(challenge_date, score desc, time_seconds asc, completed_at asc);
alter table public.daily_challenge_attempts enable row level security;
revoke all on public.daily_challenge_attempts from anon, authenticated;

create table if not exists public.user_reward_balances (
  user_id uuid primary key references auth.users(id) on delete cascade,
  reward_points integer not null default 0,
  daily_challenges_completed integer not null default 0,
  updated_at timestamptz not null default now(),
  constraint reward_balance_check check (reward_points >= 0 and daily_challenges_completed >= 0)
);
alter table public.user_reward_balances enable row level security;
revoke all on public.user_reward_balances from anon, authenticated;

-- Questions are returned without correct_index; grading happens only in submit_daily_challenge.
create or replace function public.get_or_create_daily_challenge(p_challenge_date date default current_date)
returns jsonb language plpgsql security definer set search_path=public,extensions
as 'declare ids uuid[]; result jsonb; begin
  if p_challenge_date<current_date-interval ''1 day'' or p_challenge_date>current_date+interval ''30 days'' then raise exception ''invalid challenge date''; end if;
  select question_ids into ids from public.daily_challenges where challenge_date=p_challenge_date and status=''ready'';
  if ids is null then
    select array_agg(id) into ids from (select id from public.battle_questions where status=''active'' and ''daily''=any(allowed_modes) order by random() limit 10) s;
    if ids is null or cardinality(ids)<10 then raise exception ''daily challenge bank needs at least 10 active questions''; end if;
    insert into public.daily_challenges(challenge_date,question_ids) values(p_challenge_date,ids) on conflict(challenge_date) do nothing;
    select question_ids into ids from public.daily_challenges where challenge_date=p_challenge_date and status=''ready'';
  end if;
  select jsonb_build_object(''challenge_date'',p_challenge_date,''questions'',coalesce(jsonb_agg(q order by array_position(ids,q.id)),''[]''::jsonb)) into result
  from (select id,category,question,options from public.battle_questions where id=any(ids)) q;
  return result;
end';
revoke all on function public.get_or_create_daily_challenge(date) from public;
grant execute on function public.get_or_create_daily_challenge(date) to anon,authenticated;

create or replace function public.submit_daily_challenge(p_challenge_date date default current_date,p_answers jsonb default ''[]''::jsonb,p_time_seconds numeric default 0)
returns jsonb language plpgsql security definer set search_path=public,extensions
as 'declare u uuid:=auth.uid(); ids uuid[]; existing public.daily_challenge_attempts%rowtype; i int; answer int; correct int:=0; total int; safe_time numeric; streak int:=1; prior date; score int; reward int; result jsonb; begin
  if u is null then raise exception ''authentication required''; end if;
  if p_challenge_date<>current_date then raise exception ''challenge is available today only''; end if;
  if jsonb_typeof(p_answers)<>''array'' then raise exception ''invalid answers''; end if;
  select question_ids into ids from public.daily_challenges where challenge_date=p_challenge_date and status=''ready'' for update;
  if ids is null then raise exception ''daily challenge not found''; end if;
  total:=cardinality(ids);
  if jsonb_array_length(p_answers)<>total then raise exception ''all questions must be answered''; end if;
  if p_time_seconds is null or p_time_seconds<0 or p_time_seconds>1800 then raise exception ''invalid completion time''; end if;
  safe_time:=round(p_time_seconds,1);
  select * into existing from public.daily_challenge_attempts where challenge_date=p_challenge_date and user_id=u;
  if found then return jsonb_build_object(''already_completed'',true,''correct_answers'',existing.correct_answers,''total_questions'',existing.total_questions,''time_seconds'',existing.time_seconds,''score'',existing.score,''reward_points'',existing.reward_points,''streak_days'',existing.streak_days,''completed_at'',existing.completed_at); end if;
  for i in 1..total loop
    answer:=case when jsonb_typeof(p_answers->(i-1))=''number'' then (p_answers->>(i-1))::int else -1 end;
    if answer<0 or answer>3 then raise exception ''invalid answer index''; end if;
    if answer=(select correct_index from public.battle_questions where id=ids[i]) then correct:=correct+1; end if;
  end loop;
  prior:=p_challenge_date-1;
  while prior>=p_challenge_date-365 loop
    exit when not exists(select 1 from public.daily_challenge_attempts where challenge_date=prior and user_id=u);
    streak:=streak+1; prior:=prior-1;
  end loop;
  score:=correct*100 + greatest(0,300-floor(safe_time)::int) + least(100,(streak-1)*10);
  reward:=10 + correct*5 + least(50,(streak-1)*5) + case when safe_time<=60 then 10 else 0 end;
  insert into public.daily_challenge_attempts(challenge_date,user_id,correct_answers,total_questions,time_seconds,score,reward_points,streak_days,answers) values(p_challenge_date,u,correct,total,safe_time,score,reward,streak,p_answers);
  return jsonb_build_object(''already_completed'',false,''correct_answers'',correct,''total_questions'',total,''time_seconds'',safe_time,''score'',score,''reward_points'',reward,''streak_days'',streak); end';
revoke all on function public.submit_daily_challenge(date,jsonb,numeric) from public;
grant execute on function public.submit_daily_challenge(date,jsonb,numeric) to authenticated;

create or replace function public.get_daily_challenge_leaderboard(p_challenge_date date default current_date)
returns jsonb language sql security definer set search_path=public,extensions
as 'select jsonb_build_object(
  ''challenge_date'',p_challenge_date,
  ''entries'',coalesce((select jsonb_agg(x order by x.rank) from (select rank() over(order by a.score desc,a.time_seconds asc,a.completed_at asc)::int as rank,coalesce(p.full_name,''لاعب'') as player_name,a.correct_answers,a.total_questions,a.time_seconds,a.score,a.reward_points,a.streak_days,(a.user_id=auth.uid()) as is_me from public.daily_challenge_attempts a left join public.profiles p on p.id=a.user_id where a.challenge_date=p_challenge_date limit 50) x),''[]''::jsonb),
  ''my_attempt'',(select jsonb_build_object(''correct_answers'',a.correct_answers,''total_questions'',a.total_questions,''time_seconds'',a.time_seconds,''score'',a.score,''reward_points'',a.reward_points,''streak_days'',a.streak_days) from public.daily_challenge_attempts a where a.challenge_date=p_challenge_date and a.user_id=auth.uid())
)';
revoke all on function public.get_daily_challenge_leaderboard(date) from public;
grant execute on function public.get_daily_challenge_leaderboard(date) to anon,authenticated;

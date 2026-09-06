-- Central game question bank: one question, multiple internal destinations.
-- Destinations: battle, private, bot, daily, tournament.

alter table public.battle_questions
  add column if not exists status text not null default 'active',
  add column if not exists difficulty text not null default 'medium',
  add column if not exists allowed_modes text[] not null default array['battle','private','bot'],
  add column if not exists times_used integer not null default 0,
  add column if not exists last_used_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

update public.battle_questions
set status = coalesce(nullif(status, ''), 'active'),
    difficulty = coalesce(nullif(difficulty, ''), 'medium'),
    allowed_modes = case when allowed_modes is null or cardinality(allowed_modes) = 0 then array['battle','private','bot'] else allowed_modes end
where status is null or difficulty is null or allowed_modes is null or cardinality(allowed_modes) = 0;

-- Existing approved game questions are eligible for the daily branch as well.
update public.battle_questions
set allowed_modes = array(select distinct unnest(allowed_modes || array['daily']))
where status = 'active' and not ('daily' = any(allowed_modes));

alter table public.battle_questions
  drop constraint if exists battle_questions_status_check,
  drop constraint if exists battle_questions_difficulty_check;
alter table public.battle_questions
  add constraint battle_questions_status_check check (status in ('draft','active','paused','archived')),
  add constraint battle_questions_difficulty_check check (difficulty in ('easy','medium','hard'));

create index if not exists battle_questions_mode_idx on public.battle_questions using gin (allowed_modes);
create index if not exists battle_questions_active_category_idx on public.battle_questions (category, status, difficulty);

create table if not exists public.battle_question_usage (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.battle_questions(id) on delete cascade,
  usage_mode text not null,
  context_id uuid,
  user_id uuid references auth.users(id) on delete set null,
  used_at timestamptz not null default now(),
  constraint battle_question_usage_mode_check check (usage_mode in ('battle','private','bot','daily','tournament'))
);
create index if not exists battle_question_usage_question_idx on public.battle_question_usage(question_id, used_at desc);
create index if not exists battle_question_usage_context_idx on public.battle_question_usage(usage_mode, context_id);
alter table public.battle_question_usage enable row level security;
revoke all on public.battle_question_usage from anon, authenticated;

create table if not exists public.daily_challenges (
  challenge_date date primary key,
  question_ids uuid[] not null,
  status text not null default 'ready',
  generated_by text not null default 'automatic',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint daily_challenges_status_check check (status in ('draft','ready','paused','archived')),
  constraint daily_challenges_generator_check check (generated_by in ('automatic','admin'))
);
alter table public.daily_challenges enable row level security;
revoke all on public.daily_challenges from anon, authenticated;

create or replace function public.insert_battle_questions_bulk(p_passphrase text default null, p_questions jsonb default '[]'::jsonb)
returns integer language plpgsql security definer set search_path = public, extensions
as 'declare inserted_count int; q jsonb; modes text[]; v_status text; v_difficulty text; begin
  if not public.admin_authorized(p_passphrase) then raise exception ''invalid admin session''; end if;
  if jsonb_typeof(p_questions) <> ''array'' or jsonb_array_length(p_questions) > 500 then raise exception ''invalid question batch''; end if;
  for q in select value from jsonb_array_elements(p_questions) loop
    modes := case when jsonb_typeof(q->''allowed_modes'') = ''array'' then array(select jsonb_array_elements_text(q->''allowed_modes'')) else array[''battle'',''private'',''bot''] end;
    v_status := coalesce(nullif(q->>''status'', ''''), ''active'');
    v_difficulty := coalesce(nullif(q->>''difficulty'', ''''), ''medium'');
    if v_status not in (''draft'',''active'',''paused'',''archived'') then raise exception ''invalid question status''; end if;
    if v_difficulty not in (''easy'',''medium'',''hard'') then raise exception ''invalid question difficulty''; end if;
    if cardinality(modes) = 0 or exists(select 1 from unnest(modes) m where m not in (''battle'',''private'',''bot'',''daily'',''tournament'')) then raise exception ''invalid question destination''; end if;
    if length(coalesce(q->>''question'', '''')) < 3 or jsonb_typeof(q->''options'') <> ''array'' or jsonb_array_length(q->''options'') < 2 or (q->>''correct_index'')::int < 0 or (q->>''correct_index'')::int >= jsonb_array_length(q->''options'') then raise exception ''invalid question payload''; end if;
    insert into public.battle_questions(category,question,options,correct_index,status,difficulty,allowed_modes,updated_at)
    values (nullif(btrim(q->>''category''),''''), btrim(q->>''question''), q->''options'', (q->>''correct_index'')::int, v_status, v_difficulty, modes, now());
  end loop;
  get diagnostics inserted_count = row_count;
  return inserted_count;
end';

revoke all on function public.insert_battle_questions_bulk(text,jsonb) from public;
grant execute on function public.insert_battle_questions_bulk(text,jsonb) to anon, authenticated;

create or replace function public.get_random_battle_questions_for_mode(p_category text default 'مختلط', p_mode text default 'battle', p_count integer default 10)
returns jsonb language plpgsql security definer set search_path = public, extensions
as 'declare result jsonb; selected_ids uuid[]; begin
  if p_mode not in (''battle'',''private'',''bot'',''daily'',''tournament'') then raise exception ''invalid question mode''; end if;
  if p_count < 1 or p_count > 50 then raise exception ''invalid question count''; end if;
  select array_agg(id) into selected_ids from (
    select id from public.battle_questions
    where status = ''active'' and p_mode = any(allowed_modes) and (p_category is null or p_category = ''مختلط'' or category = p_category)
    order by random() limit p_count
  ) s;
  if selected_ids is null or cardinality(selected_ids) < p_count then raise exception ''not enough active questions for requested mode''; end if;
  update public.battle_questions set times_used = times_used + 1, last_used_at = now(), updated_at = now() where id = any(selected_ids);
  insert into public.battle_question_usage(question_id, usage_mode) select unnest(selected_ids), p_mode;
  select coalesce(jsonb_agg(t), ''[]''::jsonb) into result from (
    select id, category, question, options, correct_index from public.battle_questions where id = any(selected_ids)
  ) t;
  return result;
end';
revoke all on function public.get_random_battle_questions_for_mode(text,text,integer) from public;
grant execute on function public.get_random_battle_questions_for_mode(text,text,integer) to anon, authenticated;

create or replace function public.get_or_create_daily_challenge(p_challenge_date date default current_date)
returns jsonb language plpgsql security definer set search_path = public, extensions
as 'declare ids uuid[]; result jsonb; begin
  select question_ids into ids from public.daily_challenges where challenge_date = p_challenge_date and status = ''ready'';
  if ids is null then
    select array_agg(id) into ids from (select id from public.battle_questions where status = ''active'' and ''daily'' = any(allowed_modes) order by random() limit 10) s;
    if ids is null or cardinality(ids) < 10 then raise exception ''daily challenge bank needs at least 10 active questions''; end if;
    insert into public.daily_challenges(challenge_date,question_ids) values(p_challenge_date,ids) on conflict (challenge_date) do nothing;
    select question_ids into ids from public.daily_challenges where challenge_date = p_challenge_date and status = ''ready'';
  end if;
  update public.battle_questions set times_used = times_used + 1, last_used_at = now(), updated_at = now() where id = any(ids);
  insert into public.battle_question_usage(question_id,usage_mode,context_id,user_id) select unnest(ids), ''daily'', null, auth.uid();
  select coalesce(jsonb_agg(q order by array_position(ids, q.id)), ''[]''::jsonb) into result from (select id,category,question,options,correct_index from public.battle_questions where id = any(ids)) q;
  return result;
end';
revoke all on function public.get_or_create_daily_challenge(date) from public;
grant execute on function public.get_or_create_daily_challenge(date) to anon, authenticated;

create or replace function public.get_battle_bank_stats(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as 'declare result jsonb; begin
  if not public.admin_authorized(p_passphrase) then raise exception ''invalid admin session''; end if;
  select coalesce(jsonb_agg(x), ''[]''::jsonb) into result from (
    select category, status, difficulty, mode, count(*)::int as total from public.battle_questions cross join lateral unnest(allowed_modes) mode group by category,status,difficulty,mode order by category,status,difficulty,mode
  ) x; return result;
end';
revoke all on function public.get_battle_bank_stats(text) from public;
grant execute on function public.get_battle_bank_stats(text) to anon, authenticated;

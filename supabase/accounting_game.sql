-- Accounting Journal Game: isolated question bank, attempts, and admin RPCs.
create table if not exists public.accounting_game_questions (
  id uuid primary key default gen_random_uuid(),
  scenario text not null check (length(btrim(scenario)) between 5 and 500),
  debit_account text not null check (length(btrim(debit_account)) between 1 and 120),
  credit_account text not null check (length(btrim(credit_account)) between 1 and 120),
  options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 12),
  explanation text not null default '',
  category text not null default 'محاسبة مالية',
  difficulty text not null default 'easy' check (difficulty in ('easy','medium','hard')),
  status text not null default 'active' check (status in ('draft','active','paused')),
  created_at timestamptz not null default now()
);

create table if not exists public.accounting_game_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  session_id text,
  score integer not null default 0 check (score >= 0),
  correct_count integer not null default 0 check (correct_count >= 0),
  total_questions integer not null default 0 check (total_questions >= 0),
  hearts_spent integer not null default 0 check (hearts_spent >= 0),
  reward_points integer not null default 0 check (reward_points >= 0),
  category text,
  created_at timestamptz not null default now()
);

alter table public.accounting_game_questions enable row level security;
alter table public.accounting_game_attempts enable row level security;
revoke all on public.accounting_game_questions from anon, authenticated;
revoke all on public.accounting_game_attempts from anon, authenticated;

create or replace function public.get_accounting_game_questions(p_limit integer default 10, p_category text default null, p_difficulty text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if p_limit is null or p_limit < 1 or p_limit > 20 then p_limit := 10; end if;
  select coalesce(jsonb_agg(row_to_json(q)), '[]'::jsonb) into result
  from (
    select id, scenario, debit_account, credit_account, options, explanation, category, difficulty
    from public.accounting_game_questions
    where status = 'active'
      and (p_category is null or category = p_category)
      and (p_difficulty is null or difficulty = p_difficulty)
    order by random()
    limit p_limit
  ) q;
  return result;
end;
$$;

create or replace function public.save_accounting_game_attempt(
  p_session_id text, p_score integer, p_correct_count integer, p_total_questions integer,
  p_hearts_spent integer, p_reward_points integer, p_category text default null
)
returns uuid language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if p_score is null or p_score < 0 or p_score > 1000000 then raise exception 'invalid score'; end if;
  if p_correct_count is null or p_correct_count < 0 or p_total_questions is null or p_total_questions < 0 or p_correct_count > p_total_questions then raise exception 'invalid question counts'; end if;
  if p_hearts_spent is null or p_hearts_spent < 0 or p_hearts_spent > 20 then raise exception 'invalid hearts'; end if;
  if p_reward_points is null or p_reward_points < 0 or p_reward_points > 1000000 then raise exception 'invalid rewards'; end if;
  insert into public.accounting_game_attempts(user_id,session_id,score,correct_count,total_questions,hearts_spent,reward_points,category)
  values(auth.uid(), left(nullif(btrim(p_session_id),''),120), p_score,p_correct_count,p_total_questions,p_hearts_spent,p_reward_points,nullif(left(btrim(coalesce(p_category,'')),80),''))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.get_accounting_game_stats(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select jsonb_build_object(
    'total_attempts', count(*)::integer,
    'unique_players', count(distinct user_id)::integer,
    'today_attempts', count(*) filter (where created_at >= current_date)::integer,
    'week_attempts', count(*) filter (where created_at >= current_date - interval '6 days')::integer,
    'avg_score', coalesce(round(avg(score)::numeric,1),0),
    'avg_accuracy', coalesce(round(avg(case when total_questions > 0 then correct_count::numeric * 100 / total_questions else 0 end),1),0),
    'completed_rounds', count(*) filter (where correct_count = total_questions and total_questions > 0)::integer
  ) into result
  from public.accounting_game_attempts;
  return result;
end;
$$;

create or replace function public.get_accounting_game_bank(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(row_to_json(q) order by q.created_at desc), '[]'::jsonb) into result
  from (select id,scenario,debit_account,credit_account,options,explanation,category,difficulty,status,created_at from public.accounting_game_questions) q;
  return result;
end;
$$;

create or replace function public.insert_accounting_game_questions_bulk(p_passphrase text default null, p_questions jsonb default '[]'::jsonb)
returns integer language plpgsql security definer set search_path = public, extensions
as $$
declare inserted_count int;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  if jsonb_array_length(p_questions) > 500 then raise exception 'too many questions'; end if;
  insert into public.accounting_game_questions(scenario,debit_account,credit_account,options,explanation,category,difficulty,status)
  select left(btrim(q->>'scenario'),500), left(btrim(q->>'debit_account'),120), left(btrim(q->>'credit_account'),120), q->'options', coalesce(q->>'explanation',''), coalesce(nullif(q->>'category',''),'محاسبة مالية'), coalesce(nullif(q->>'difficulty',''),'easy'), coalesce(nullif(q->>'status',''),'active')
  from jsonb_array_elements(p_questions) q;
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

create or replace function public.delete_accounting_game_question(p_passphrase text default null, p_id uuid default null)
returns boolean language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  delete from public.accounting_game_questions where id = p_id;
  return found;
end;
$$;

revoke all on function public.get_accounting_game_questions(integer,text,text) from public;
revoke all on function public.save_accounting_game_attempt(text,integer,integer,integer,integer,integer,text) from public;
revoke all on function public.get_accounting_game_stats(text) from public;
revoke all on function public.get_accounting_game_bank(text) from public;
revoke all on function public.insert_accounting_game_questions_bulk(text,jsonb) from public;
revoke all on function public.delete_accounting_game_question(text,uuid) from public;
grant execute on function public.get_accounting_game_questions(integer,text,text) to anon, authenticated;
grant execute on function public.save_accounting_game_attempt(text,integer,integer,integer,integer,integer,text) to anon, authenticated;
grant execute on function public.get_accounting_game_stats(text) to anon, authenticated;
grant execute on function public.get_accounting_game_bank(text) to anon, authenticated;
grant execute on function public.insert_accounting_game_questions_bulk(text,jsonb) to anon, authenticated;
grant execute on function public.delete_accounting_game_question(text,uuid) to anon, authenticated;

insert into public.accounting_game_questions(scenario,debit_account,credit_account,options,explanation,category,difficulty,status)
select * from (values
('اشترت المنشأة بضاعة نقدًا بقيمة 10,000 جنيه.','المشتريات','الصندوق','["المشتريات","الصندوق","المبيعات","العملاء"]'::jsonb,'المشتريات زادت فتكون مدينة، والصندوق انخفض فيكون دائنًا.','محاسبة مالية','easy','active'),
('باعت المنشأة بضاعة للعميل أحمد على الحساب بقيمة 15,000 جنيه.','العملاء','المبيعات','["العملاء","المبيعات","الصندوق","الموردون"]'::jsonb,'العميل أصبح مدينًا للمنشأة، والإيراد يُثبت دائنًا.','محاسبة مالية','easy','active'),
('حصلت المنشأة 8,000 جنيه من عميل عن طريق البنك.','البنك','العملاء','["البنك","العملاء","المبيعات","الموردون"]'::jsonb,'البنك زاد مدينًا، ورصيد العميل انخفض دائنًا.','خزينة وبنوك','easy','active'),
('سددت المنشأة 12,000 جنيه لمورد عن طريق البنك.','الموردون','البنك','["الموردون","البنك","المشتريات","الصندوق"]'::jsonb,'الالتزام للمورد انخفض فيُسجل مدينًا، والبنك انخفض دائنًا.','خزينة وبنوك','easy','active'),
('دفعت المنشأة مصروف كهرباء نقدًا بقيمة 1,500 جنيه.','مصروف الكهرباء','الصندوق','["مصروف الكهرباء","الصندوق","الإيرادات","العملاء"]'::jsonb,'المصروف زاد مدينًا، والنقدية انخفضت دائنًا.','مصروفات','easy','active'),
('اشترت المنشأة جهازًا نقدًا بقيمة 25,000 جنيه.','الأصول الثابتة','الصندوق','["الأصول الثابتة","الصندوق","مصروف الإهلاك","المبيعات"]'::jsonb,'الأصل زاد مدينًا، والصندوق انخفض دائنًا.','أصول وإهلاك','medium','active'),
('إثبات إهلاك شهري لمعدة بقيمة 2,000 جنيه.','مصروف الإهلاك','مجمع إهلاك الأصل','["مصروف الإهلاك","مجمع إهلاك الأصل","الأصول الثابتة","الصندوق"]'::jsonb,'مصروف الإهلاك مدين، ومجمع الإهلاك حساب مقابل دائن.','أصول وإهلاك','medium','active'),
('استثمر المالك 50,000 جنيه نقدًا في المنشأة.','الصندوق','رأس المال','["الصندوق","رأس المال","المبيعات","الموردون"]'::jsonb,'النقدية زادت مدينًا، وحقوق الملكية زادت دائنًا.','حقوق ملكية','easy','active'),
('دفعت المنشأة إيجار المكتب مقدمًا لمدة ستة أشهر.','مصروفات مدفوعة مقدمًا','الصندوق','["مصروفات مدفوعة مقدمًا","الصندوق","مصروف الإيجار","المبيعات"]'::jsonb,'الدفع المقدم أصل متداول مدين، والنقدية دائن.','مصروفات','medium','active'),
('اشترت المنشأة بضاعة من المورد على الحساب.','المشتريات','الموردون','["المشتريات","الموردون","العملاء","البنك"]'::jsonb,'المشتريات مدينة، والالتزام للمورد دائن.','محاسبة مالية','easy','active')
) as v(scenario,debit_account,credit_account,options,explanation,category,difficulty,status)
where not exists (select 1 from public.accounting_game_questions limit 1);

comment on table public.accounting_game_questions is 'Isolated question bank for the accounting journal drag-and-drop game.';
comment on table public.accounting_game_attempts is 'Scores and attempts for the accounting journal game.';
revoke all on function public.get_accounting_game_bank(text) from public;
revoke all on function public.insert_accounting_game_questions_bulk(text,jsonb) from public;
revoke all on function public.delete_accounting_game_question(text,uuid) from public;
grant execute on function public.get_accounting_game_bank(text) to anon, authenticated;
grant execute on function public.insert_accounting_game_questions_bulk(text,jsonb) to anon, authenticated;
grant execute on function public.delete_accounting_game_question(text,uuid) to anon, authenticated;

-- Admin functions are intentionally callable only after admin_authorized() passes.
-- Public game functions expose active questions only and never expose draft/paused entries.

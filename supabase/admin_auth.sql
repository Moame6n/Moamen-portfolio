-- Secure admin authentication through Supabase Auth.
create table if not exists public.private_admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.private_admin_users enable row level security;
revoke all on public.private_admin_users from anon, authenticated;
insert into public.private_admin_users (user_id)
values ('2a7fde9f-655b-4019-a40c-b6f4de9e472a')
on conflict (user_id) do nothing;

create or replace function public.admin_authorized(p_passphrase text default null)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if exists (select 1 from public.private_admin_users where user_id = auth.uid()) then
    return true;
  end if;
  return false;
end;
$$;

revoke all on function public.admin_authorized(text) from public;
grant execute on function public.admin_authorized(text) to anon, authenticated;

create or replace function public.list_exam_slugs(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into result
  from (select exam_slug, exam_title, count(*) as attempts from exam_attempts group by exam_slug, exam_title order by max(finished_at) desc) x;
  return result;
end;
$$;

create or replace function public.get_exam_results(p_exam_slug text, p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(t), '[]'::jsonb) into result from (select * from exam_attempts where exam_slug = p_exam_slug order by finished_at desc) t;
  return result;
end;
$$;

create or replace function public.get_page_view_stats(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  pv_total bigint; pv_today bigint; pv_7d bigint;
  sessions_total bigint; sessions_today bigint; sessions_7d bigint;
  users_total bigint; users_today bigint; users_7d bigint;
  by_path jsonb; daily jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select count(*) into pv_total from page_views;
  select count(*) into pv_today from page_views where viewed_at >= date_trunc('day', now());
  select count(*) into pv_7d from page_views where viewed_at >= now() - interval '7 days';
  select count(distinct session_id) into sessions_total from page_views where session_id is not null;
  select count(distinct session_id) into sessions_today from page_views where session_id is not null and viewed_at >= date_trunc('day', now());
  select count(distinct session_id) into sessions_7d from page_views where session_id is not null and viewed_at >= now() - interval '7 days';
  select count(distinct client_id) into users_total from page_views where client_id is not null;
  select count(distinct client_id) into users_today from page_views where client_id is not null and viewed_at >= date_trunc('day', now());
  select count(distinct client_id) into users_7d from page_views where client_id is not null and viewed_at >= now() - interval '7 days';
  select coalesce(jsonb_agg(x), '[]'::jsonb) into by_path from (select path, count(*) as views, count(distinct session_id) as sessions from page_views group by path order by count(*) desc limit 15) x;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into daily from (
    select to_char(d::date, 'YYYY-MM-DD') as day, coalesce(pv.cnt, 0) as views, coalesce(sv.cnt, 0) as sessions
    from generate_series(current_date - interval '13 days', current_date, interval '1 day') d
    left join (select date_trunc('day', viewed_at)::date as vd, count(*) as cnt from page_views where viewed_at >= current_date - interval '13 days' group by 1) pv on pv.vd = d::date
    left join (select date_trunc('day', viewed_at)::date as vd, count(distinct session_id) as cnt from page_views where viewed_at >= current_date - interval '13 days' and session_id is not null group by 1) sv on sv.vd = d::date
    order by d
  ) x;
  return jsonb_build_object(
    'pageviews', jsonb_build_object('total', pv_total, 'today', pv_today, 'last7', pv_7d),
    'sessions', jsonb_build_object('total', sessions_total, 'today', sessions_today, 'last7', sessions_7d),
    'users', jsonb_build_object('total', users_total, 'today', users_today, 'last7', users_7d),
    'by_path', by_path, 'daily', daily
  );
end;
$$;

create or replace function public.get_battle_bank_stats(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into result from (select category, count(*) as total from battle_questions group by category order by category) x;
  return result;
end;
$$;

create or replace function public.get_battle_history(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(t), '[]'::jsonb) into result from (select * from battle_results order by created_at desc limit 100) t;
  return result;
end;
$$;

revoke all on function public.list_exam_slugs(text) from public;
revoke all on function public.get_exam_results(text,text) from public;
revoke all on function public.get_page_view_stats(text) from public;
revoke all on function public.get_battle_bank_stats(text) from public;
revoke all on function public.get_battle_history(text) from public;
grant execute on function public.list_exam_slugs(text) to anon, authenticated;
grant execute on function public.get_exam_results(text,text) to anon, authenticated;
grant execute on function public.get_page_view_stats(text) to anon, authenticated;
grant execute on function public.get_battle_bank_stats(text) to anon, authenticated;
grant execute on function public.get_battle_history(text) to anon, authenticated;

comment on table public.private_admin_users is 'Private allowlist of Supabase Auth user IDs permitted to use admin RPCs.';
comment on function public.admin_authorized(text) is 'Authorizes only an authenticated Supabase user in the private admin allowlist.';

-- Profile data is private to its owner.
drop policy if exists "profiles owner select" on public.profiles;
create policy "profiles owner select" on public.profiles for select to authenticated using (id = auth.uid());
drop policy if exists "profiles owner insert" on public.profiles;
create policy "profiles owner insert" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles owner update" on public.profiles;
create policy "profiles owner update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- User activity is exposed through get_my_activity(), not direct table reads.
revoke all on public.profiles from anon;
revoke all on public.profiles from authenticated;
grant select, insert, update on public.profiles to authenticated;
revoke all on function public.get_my_activity() from public;
grant execute on function public.get_my_activity() to authenticated;

-- The function itself already enforces auth.uid(); keep its security-definer search path fixed.
comment on function public.get_my_activity() is 'Returns only the authenticated caller activity.';

-- Storage bucket policies should be reviewed in Dashboard if the bucket was created manually.
-- The client continues to use the existing avatars bucket and same-user object path.

create or replace function public.get_template_leads(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(t), '[]'::jsonb) into result from (select * from template_downloads order by downloaded_at desc) t;
  return result;
end;
$$;

create or replace function public.get_feedback_list(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(t), '[]'::jsonb) into result from (select * from user_feedback order by created_at desc) t;
  return result;
end;
$$;

create or replace function public.insert_battle_questions_bulk(p_passphrase text default null, p_questions jsonb default '[]'::jsonb)
returns integer language plpgsql security definer set search_path = public, extensions
as $$
declare inserted_count int;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  if jsonb_array_length(p_questions) > 500 then raise exception 'too many questions'; end if;
  insert into battle_questions (category, question, options, correct_index)
  select (q->>'category')::text, (q->>'question')::text, (q->'options')::jsonb, (q->>'correct_index')::int
  from jsonb_array_elements(p_questions) as q;
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

revoke all on function public.get_template_leads(text) from public;
revoke all on function public.get_feedback_list(text) from public;
revoke all on function public.insert_battle_questions_bulk(text,jsonb) from public;
grant execute on function public.get_template_leads(text) to anon, authenticated;
grant execute on function public.get_feedback_list(text) to anon, authenticated;
grant execute on function public.insert_battle_questions_bulk(text,jsonb) to anon, authenticated;

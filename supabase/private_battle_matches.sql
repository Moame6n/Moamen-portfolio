-- Private friend-to-friend battle rooms.
-- The table is intentionally closed to direct public reads/writes; the browser uses the
-- narrowly scoped SECURITY DEFINER RPCs below.
create extension if not exists pgcrypto;

create table if not exists public.private_battle_matches (
  id uuid primary key default gen_random_uuid(),
  invite_code text not null unique,
  host_name text not null,
  guest_name text,
  category text not null default 'مختلط',
  status text not null default 'waiting',
  questions jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 hours'),
  constraint private_battle_matches_status_check check (status in ('waiting', 'ready', 'active', 'finished', 'cancelled')),
  constraint private_battle_matches_host_name_check check (length(btrim(host_name)) between 1 and 160),
  constraint private_battle_matches_guest_name_check check (guest_name is null or length(btrim(guest_name)) between 1 and 160),
  constraint private_battle_matches_category_check check (length(btrim(category)) between 1 and 80)
);

create index if not exists private_battle_matches_code_idx on public.private_battle_matches(invite_code);
create index if not exists private_battle_matches_status_expires_idx on public.private_battle_matches(status, expires_at);

alter table public.private_battle_matches enable row level security;
revoke all on table public.private_battle_matches from anon, authenticated;

create or replace function public.generate_private_battle_code()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text;
begin
  loop
    v_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 8));
    exit when not exists (
      select 1 from public.private_battle_matches where invite_code = v_code
    );
  end loop;
  return v_code;
end;
$$;
revoke all on function public.generate_private_battle_code() from public;

create or replace function public.create_private_battle(
  p_host_name text,
  p_category text default 'مختلط'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_code text;
  v_category text := coalesce(nullif(btrim(p_category), ''), 'مختلط');
begin
  if p_host_name is null or length(btrim(p_host_name)) < 1 or length(p_host_name) > 160 then
    raise exception 'invalid host name';
  end if;
  if length(v_category) > 80 then
    raise exception 'invalid category';
  end if;

  v_code := public.generate_private_battle_code();
  insert into public.private_battle_matches (invite_code, host_name, category)
  values (v_code, btrim(p_host_name), v_category)
  returning id into v_id;

  return jsonb_build_object(
    'match_id', v_id,
    'invite_code', v_code,
    'host_name', btrim(p_host_name),
    'category', v_category,
    'status', 'waiting'
  );
end;
$$;
revoke all on function public.create_private_battle(text,text) from public;
grant execute on function public.create_private_battle(text,text) to anon, authenticated;

create or replace function public.get_private_battle(p_invite_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_match public.private_battle_matches%rowtype;
begin
  select * into v_match
  from public.private_battle_matches
  where invite_code = upper(btrim(p_invite_code))
    and expires_at > now()
    and status <> 'cancelled'
  limit 1;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'match_id', v_match.id,
    'invite_code', v_match.invite_code,
    'host_name', v_match.host_name,
    'guest_name', v_match.guest_name,
    'category', v_match.category,
    'status', v_match.status,
    'questions', case when v_match.status = 'active' then coalesce(v_match.questions, '[]'::jsonb) else null end,
    'expires_at', v_match.expires_at
  );
end;
$$;
revoke all on function public.get_private_battle(text) from public;
grant execute on function public.get_private_battle(text) to anon, authenticated;

create or replace function public.join_private_battle(
  p_invite_code text,
  p_guest_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_match public.private_battle_matches%rowtype;
  v_guest_name text := btrim(p_guest_name);
begin
  if v_guest_name is null or length(v_guest_name) < 1 or length(v_guest_name) > 160 then
    raise exception 'invalid guest name';
  end if;

  select * into v_match
  from public.private_battle_matches
  where invite_code = upper(btrim(p_invite_code))
    and expires_at > now()
    and status <> 'cancelled'
  for update;

  if not found then
    raise exception 'private match not found or expired';
  end if;

  if v_match.guest_name is null and v_match.status = 'waiting' then
    update public.private_battle_matches
    set guest_name = v_guest_name, status = 'ready', updated_at = now()
    where id = v_match.id
    returning * into v_match;
  elsif v_match.guest_name is distinct from v_guest_name then
    raise exception 'private match already has a guest';
  end if;

  return jsonb_build_object(
    'match_id', v_match.id,
    'invite_code', v_match.invite_code,
    'host_name', v_match.host_name,
    'guest_name', v_match.guest_name,
    'category', v_match.category,
    'status', v_match.status,
    'questions', case when v_match.status = 'active' then coalesce(v_match.questions, '[]'::jsonb) else null end,
    'expires_at', v_match.expires_at
  );
end;
$$;
revoke all on function public.join_private_battle(text,text) from public;
grant execute on function public.join_private_battle(text,text) to anon, authenticated;

create or replace function public.start_private_battle(
  p_invite_code text,
  p_questions jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_match public.private_battle_matches%rowtype;
begin
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) <> 10 then
    raise exception 'private battle requires exactly 10 questions';
  end if;

  select * into v_match
  from public.private_battle_matches
  where invite_code = upper(btrim(p_invite_code))
    and expires_at > now()
    and status <> 'cancelled'
  for update;

  if not found or v_match.guest_name is null then
    raise exception 'private match is not ready';
  end if;

  if v_match.status = 'ready' then
    update public.private_battle_matches
    set status = 'active', questions = p_questions, updated_at = now()
    where id = v_match.id
    returning * into v_match;
  elsif v_match.status <> 'active' then
    raise exception 'private match cannot be started';
  end if;

  return jsonb_build_object(
    'match_id', v_match.id,
    'invite_code', v_match.invite_code,
    'host_name', v_match.host_name,
    'guest_name', v_match.guest_name,
    'category', v_match.category,
    'status', v_match.status,
    'questions', coalesce(v_match.questions, '[]'::jsonb),
    'expires_at', v_match.expires_at
  );
end;
$$;
revoke all on function public.start_private_battle(text,jsonb) from public;
grant execute on function public.start_private_battle(text,jsonb) to anon, authenticated;

create or replace function public.finish_private_battle(p_invite_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.private_battle_matches
  set status = 'finished', updated_at = now()
  where invite_code = upper(btrim(p_invite_code))
    and status in ('active', 'ready');
  return found;
end;
$$;
revoke all on function public.finish_private_battle(text) from public;
grant execute on function public.finish_private_battle(text) to anon, authenticated;

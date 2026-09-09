-- Real tool analytics: keep page opens in tool_usage and record meaningful actions here.
create table if not exists public.tool_events (
  id uuid primary key default gen_random_uuid(),
  tool_slug text not null check (length(btrim(tool_slug)) between 1 and 160),
  event_type text not null check (event_type in ('interaction','completion')),
  action text not null check (length(btrim(action)) between 1 and 120),
  user_id uuid references auth.users(id) on delete set null,
  client_id text check (client_id is null or length(client_id) <= 120),
  session_id text check (session_id is null or length(session_id) <= 120),
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

alter table public.tool_events enable row level security;
revoke all on public.tool_events from anon, authenticated;
drop policy if exists "public can record tool events" on public.tool_events;
create policy "public can record tool events" on public.tool_events
  for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());
grant insert on public.tool_events to anon, authenticated;

create or replace function public.get_tool_event_stats(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select jsonb_build_object(
    'total_interactions', count(*) filter (where event_type='interaction'),
    'total_completions', count(*) filter (where event_type='completion'),
    'today_interactions', count(*) filter (where event_type='interaction' and occurred_at >= date_trunc('day', now())),
    'today_completions', count(*) filter (where event_type='completion' and occurred_at >= date_trunc('day', now())),
    'by_tool', coalesce((select jsonb_agg(x) from (
      select tool_slug,
        count(*) filter (where event_type='interaction') as interactions,
        count(*) filter (where event_type='completion') as completions,
        max(occurred_at) as last_event
      from public.tool_events group by tool_slug order by count(*) desc limit 50
    ) x), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(x) from (
      select to_char(d::date,'YYYY-MM-DD') as day,
        count(e.id) filter (where e.event_type='interaction') as interactions,
        count(e.id) filter (where e.event_type='completion') as completions
      from generate_series(current_date - interval '13 days', current_date, interval '1 day') d
      left join public.tool_events e on e.occurred_at >= d and e.occurred_at < d + interval '1 day'
      group by d order by d
    ) x), '[]'::jsonb)
  ) into result
  from public.tool_events;
  return result;
end;
$$;
revoke all on function public.get_tool_event_stats(text) from public;
grant execute on function public.get_tool_event_stats(text) to anon, authenticated;

comment on table public.tool_events is 'Real tool interactions and completed operations; page opens remain in tool_usage.';

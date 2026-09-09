-- Read-only tool usage analytics for the private admin dashboard.
-- Country is intentionally not inferred: tool_usage does not store IP or location data.
create or replace function public.get_tool_usage_stats(p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_total bigint;
  v_today bigint;
  v_last7 bigint;
  v_unique_users bigint;
  v_anonymous bigint;
  v_by_tool jsonb;
  v_daily jsonb;
begin
  if not public.admin_authorized(p_passphrase) then
    raise exception 'invalid admin session';
  end if;

  select count(*) into v_total from public.tool_usage;
  select count(*) into v_today from public.tool_usage where used_at >= date_trunc('day', now());
  select count(*) into v_last7 from public.tool_usage where used_at >= now() - interval '7 days';
  select count(distinct user_id) into v_unique_users from public.tool_usage where user_id is not null;
  select count(*) into v_anonymous from public.tool_usage where user_id is null;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_by_tool
  from (
    select tool_slug, max(tool_title) as tool_title, count(*) as uses,
           count(distinct user_id) filter (where user_id is not null) as unique_users,
           max(used_at) as last_used
    from public.tool_usage
    group by tool_slug
    order by count(*) desc, max(used_at) desc
    limit 50
  ) x;

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_daily
  from (
    select to_char(d::date, 'YYYY-MM-DD') as day, coalesce(u.cnt, 0) as uses
    from generate_series(current_date - interval '13 days', current_date, interval '1 day') d
    left join (
      select date_trunc('day', used_at)::date as usage_day, count(*) as cnt
      from public.tool_usage
      where used_at >= current_date - interval '13 days'
      group by 1
    ) u on u.usage_day = d::date
    order by d
  ) x;

  return jsonb_build_object(
    'total', v_total,
    'today', v_today,
    'last7', v_last7,
    'unique_users', v_unique_users,
    'anonymous', v_anonymous,
    'by_tool', v_by_tool,
    'daily', v_daily
  );
end;
$$;

revoke all on function public.get_tool_usage_stats(text) from public;
grant execute on function public.get_tool_usage_stats(text) to anon, authenticated;

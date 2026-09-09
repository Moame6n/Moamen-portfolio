-- Admin-only visitor analytics for Accounting Journal Game.
-- Uses existing anonymous client/session identifiers; no IP or location data is stored.
create or replace function public.get_accounting_game_visitor_stats(p_passphrase text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  result jsonb;
  v_path text := '/accounting-journal-game.html';
begin
  if not public.admin_authorized(p_passphrase) then
    raise exception 'invalid admin session';
  end if;

  select jsonb_build_object(
    'total_views', count(*)::integer,
    'unique_visitors', count(distinct nullif(client_id, ''))::integer,
    'today_views', count(*) filter (where viewed_at >= date_trunc('day', now()))::integer,
    'week_views', count(*) filter (where viewed_at >= now() - interval '7 days')::integer,
    'today_sessions', count(distinct nullif(session_id, '')) filter (where viewed_at >= date_trunc('day', now()))::integer,
    'week_sessions', count(distinct nullif(session_id, '')) filter (where viewed_at >= now() - interval '7 days')::integer
  ) into result
  from public.page_views
  where path in (v_path, '/accounting-journal-game', '/accounting-journal-game/');

  return result;
end;
$$;

revoke all on function public.get_accounting_game_visitor_stats(text) from public;
grant execute on function public.get_accounting_game_visitor_stats(text) to anon, authenticated;

comment on function public.get_accounting_game_visitor_stats(text) is
  'Admin-only anonymous visitor counters for the Accounting Journal Game page.';

-- The function returns aggregate counters only, never visitor identifiers.

-- The hardening migration revokes public execution from admin RPCs. These
-- grants allow an authenticated admin session to reach the functions, while
-- each function still enforces admin_authorized() internally.
grant execute on function public.get_accounting_game_bank(text) to authenticated;
grant execute on function public.get_accounting_game_stats(text) to authenticated;
grant execute on function public.insert_accounting_game_questions_bulk(text, jsonb) to authenticated;
grant execute on function public.delete_accounting_game_question(text, uuid) to authenticated;

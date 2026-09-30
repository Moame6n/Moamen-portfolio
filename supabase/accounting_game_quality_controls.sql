-- Quality controls for the Accounting Journal Game question bank.
-- Apply after accounting_game.sql, accounting_compound_entries.sql and accounting_game_final_hardening.sql.
-- This migration preserves the existing game and adds an approval gate for new content.
-- Reviewer references: https://www.ifrs.org/issued-standards/list-of-standards/conceptual-framework/
-- IAS 1: https://www.ifrs.org/issued-standards/list-of-standards/ias-1-presentation-of-financial-statements/
-- IAS 8: https://www.ifrs.org/issued-standards/list-of-standards/ias-8-basis-of-preparation-of-financial-statements/

alter table public.accounting_game_questions
  add column if not exists skill_code text not null default 'journal-entry-basics',
  add column if not exists standard_basis text not null default 'IFRS Conceptual Framework',
  add column if not exists standard_reference text not null default '',
  add column if not exists reviewer_note text not null default '',
  add column if not exists review_status text not null default 'approved',
  add column if not exists reviewed_by text,
  add column if not exists reviewed_at timestamptz,
  add column if not exists error_tags text[] not null default '{}';

alter table public.accounting_game_questions
  drop constraint if exists accounting_game_questions_review_status_check,
  drop constraint if exists accounting_game_questions_quality_check;

alter table public.accounting_game_questions
  add constraint accounting_game_questions_review_status_check
    check (review_status in ('draft','approved','rejected')),
  add constraint accounting_game_questions_quality_check
    check (
      length(btrim(skill_code)) between 2 and 80
      and length(btrim(standard_basis)) between 2 and 120
      and jsonb_typeof(options) = 'array'
      and jsonb_array_length(options) between 2 and 12
      and cardinality(string_to_array(debit_account, '|')) >= 1
      and cardinality(string_to_array(credit_account, '|')) >= 1
    );

-- Existing production questions remain available, but are explicitly marked as legacy-reviewed.
update public.accounting_game_questions
set review_status = 'approved',
    reviewed_at = coalesce(reviewed_at, created_at),
    standard_basis = coalesce(nullif(btrim(standard_basis), ''), 'IFRS Conceptual Framework')
where review_status is null or review_status = '';

create index if not exists accounting_game_questions_quality_idx
  on public.accounting_game_questions(review_status, status, skill_code, category, difficulty);

create or replace function public.validate_accounting_game_question_payload(p_question jsonb)
returns jsonb
language plpgsql immutable
set search_path = public, extensions
as $$
declare
  v_debit text := btrim(coalesce(p_question->>'debit_account',''));
  v_credit text := btrim(coalesce(p_question->>'credit_account',''));
  v_options jsonb := p_question->'options';
  v_account text;
  v_errors text[] := '{}';
begin
  if length(btrim(coalesce(p_question->>'scenario',''))) < 5 then v_errors := array_append(v_errors,'scenario_required'); end if;
  if v_debit = '' or v_credit = '' then v_errors := array_append(v_errors,'entry_accounts_required'); end if;
  if jsonb_typeof(v_options) <> 'array' or jsonb_array_length(v_options) < 2 or jsonb_array_length(v_options) > 12 then
    v_errors := array_append(v_errors,'options_count_invalid');
  end if;
  if v_options is not null and jsonb_typeof(v_options) = 'array' then
    foreach v_account in array string_to_array(v_debit || '|' || v_credit, '|') loop
      if not exists (select 1 from jsonb_array_elements_text(v_options) o where btrim(o) = btrim(v_account)) then
        v_errors := array_append(v_errors,'entry_account_missing_from_options');
        exit;
      end if;
    end loop;
  end if;
  if nullif(btrim(coalesce(p_question->>'standard_basis','')),'') is null then v_errors := array_append(v_errors,'standard_basis_required'); end if;
  if nullif(btrim(coalesce(p_question->>'explanation','')),'') is null then v_errors := array_append(v_errors,'explanation_required'); end if;
  return jsonb_build_object('valid', cardinality(v_errors) = 0, 'errors', to_jsonb(v_errors));
end;
$$;

create or replace function public.insert_accounting_game_questions_bulk(
  p_passphrase text default null,
  p_questions jsonb default '[]'::jsonb
)
returns integer language plpgsql security definer set search_path = public, extensions
as $$
declare inserted_count integer := 0; q jsonb; v_check jsonb; v_status text; v_review text;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  if jsonb_typeof(p_questions) <> 'array' or jsonb_array_length(p_questions) > 500 then raise exception 'invalid question batch'; end if;
  for q in select value from jsonb_array_elements(p_questions) loop
    v_check := public.validate_accounting_game_question_payload(q);
    if coalesce((v_check->>'valid')::boolean,false) = false then raise exception 'invalid accounting question: %', v_check->>'errors'; end if;
    v_status := coalesce(nullif(q->>'status',''),'draft');
    v_review := coalesce(nullif(q->>'review_status',''),'draft');
    if v_status not in ('draft','active','paused') then raise exception 'invalid question status'; end if;
    if v_review not in ('draft','approved','rejected') then raise exception 'invalid review status'; end if;
    if v_status = 'active' and v_review <> 'approved' then raise exception 'active questions must be approved'; end if;
    if v_review = 'approved' and nullif(btrim(coalesce(q->>'standard_reference','')),'') is null then raise exception 'approved questions require a standard reference'; end if;
    insert into public.accounting_game_questions(
      scenario,debit_account,credit_account,options,explanation,category,difficulty,status,entry_type,
      skill_code,standard_basis,standard_reference,reviewer_note,review_status,reviewed_by,reviewed_at,error_tags
    ) values (
      left(btrim(q->>'scenario'),500), left(btrim(q->>'debit_account'),120), left(btrim(q->>'credit_account'),120), q->'options',
      left(btrim(coalesce(q->>'explanation','')),1000), coalesce(nullif(left(btrim(q->>'category'),80),''),'محاسبة مالية'),
      coalesce(nullif(q->>'difficulty',''),'easy'), v_status, coalesce(nullif(q->>'entry_type',''),'simple'),
      coalesce(nullif(left(btrim(q->>'skill_code'),80),''),'journal-entry-basics'),
      coalesce(nullif(left(btrim(q->>'standard_basis'),120),''),'IFRS Conceptual Framework'),
      left(btrim(coalesce(q->>'standard_reference','')),300), left(btrim(coalesce(q->>'reviewer_note','')),1000), v_review,
      case when v_review='approved' then left(btrim(coalesce(q->>'reviewed_by','admin')),120) else null end,
      case when v_review='approved' then now() else null end,
      coalesce(array(select jsonb_array_elements_text(q->'error_tags')), '{}')
    );
    inserted_count := inserted_count + 1;
  end loop;
  return inserted_count;
end;
$$;

create or replace function public.get_accounting_game_bank(p_passphrase text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare result jsonb;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  select coalesce(jsonb_agg(row_to_json(q) order by q.created_at desc), '[]'::jsonb) into result
  from (
    select id,scenario,debit_account,credit_account,options,explanation,category,difficulty,status,entry_type,
      skill_code,standard_basis,standard_reference,reviewer_note,review_status,reviewed_by,reviewed_at,error_tags,created_at
    from public.accounting_game_questions
  ) q;
  return result;
end;
$$;

create or replace function public.review_accounting_game_question(
  p_passphrase text default null,
  p_id uuid default null,
  p_review_status text default 'approved',
  p_reviewer_note text default null
)
returns boolean language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  if p_review_status not in ('draft','approved','rejected') then raise exception 'invalid review status'; end if;
  if p_review_status = 'approved' and not exists (select 1 from public.accounting_game_questions where id=p_id and nullif(btrim(standard_reference),'') is not null) then raise exception 'approved questions require a standard reference'; end if;
  update public.accounting_game_questions
  set review_status=p_review_status,
      reviewer_note=coalesce(left(btrim(p_reviewer_note),1000),reviewer_note),
      reviewed_by=case when p_review_status='approved' then 'admin' else reviewed_by end,
      reviewed_at=case when p_review_status='approved' then now() else reviewed_at end,
      status=case when p_review_status='approved' and status='draft' then 'active' when p_review_status='rejected' then 'paused' when p_review_status='draft' then 'draft' else status end
  where id=p_id;
  return found;
end;
$$;

-- Only approved and active questions can enter new sessions.
create or replace function public.start_accounting_game_session()
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare uid uuid := auth.uid(); v_state public.accounting_game_player_state; v_existing public.accounting_game_sessions; v_session public.accounting_game_sessions; v_private jsonb; v_safe jsonb; v_count integer;
begin
  if uid is null then raise exception 'login_required'; end if;
  select * into v_existing from public.accounting_game_sessions where user_id=uid and status='active' and expires_at > now() order by created_at desc limit 1 for update;
  if v_existing.id is not null then
    select * into v_state from public.accounting_game_refresh_player(uid);
    select coalesce(jsonb_agg(jsonb_build_object('scenario',x->>'scenario','options',x->'options','category',x->>'category','difficulty',x->>'difficulty','entry_type',x->>'entry_type','skill_code',x->>'skill_code') order by ord),'[]'::jsonb) into v_safe from jsonb_array_elements(v_existing.questions) with ordinality as t(x,ord);
    return jsonb_build_object('session_id',v_existing.id,'questions',v_safe,'current_index',v_existing.current_index,'score',v_existing.score,'correct_count',v_existing.correct_count,'hearts_spent',v_existing.hearts_spent,'hearts',v_state.hearts,'reward_points',v_state.reward_points,'best_accuracy',v_state.best_accuracy,'status',v_existing.status);
  end if;
  select * into v_state from public.accounting_game_refresh_player(uid);
  if v_state.hearts <= 0 then raise exception 'no_hearts'; end if;
  select count(*) into v_count from public.accounting_game_sessions where user_id=uid and created_at > now() - interval '1 hour';
  if v_count >= 20 then raise exception 'rate_limit'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('scenario',scenario,'debit_account',debit_account,'credit_account',credit_account,'options',options,'explanation',explanation,'category',category,'difficulty',difficulty,'entry_type',entry_type,'skill_code',skill_code) order by ord),'[]'::jsonb) into v_private
  from (select scenario,debit_account,credit_account,options,explanation,category,difficulty,entry_type,skill_code,row_number() over () as ord from public.accounting_game_questions where status='active' and review_status='approved' order by random() limit 10) q;
  if jsonb_array_length(v_private) = 0 then raise exception 'no_questions'; end if;
  insert into public.accounting_game_sessions(user_id,questions,total_questions,expires_at) values(uid,v_private,jsonb_array_length(v_private),now()+interval '30 minutes') returning * into v_session;
  select coalesce(jsonb_agg(jsonb_build_object('scenario',x->>'scenario','options',x->'options','category',x->>'category','difficulty',x->>'difficulty','entry_type',x->>'entry_type','skill_code',x->>'skill_code') order by ord),'[]'::jsonb) into v_safe from jsonb_array_elements(v_private) with ordinality as t(x,ord);
  return jsonb_build_object('session_id',v_session.id,'questions',v_safe,'current_index',0,'score',0,'correct_count',0,'hearts_spent',0,'hearts',v_state.hearts,'reward_points',v_state.reward_points,'best_accuracy',v_state.best_accuracy,'status','active');
end;
$$;

revoke all on function public.validate_accounting_game_question_payload(jsonb) from public, anon, authenticated;
revoke all on function public.review_accounting_game_question(text,uuid,text,text) from public, anon, authenticated;
revoke all on function public.insert_accounting_game_questions_bulk(text,jsonb) from public, anon, authenticated;
revoke all on function public.get_accounting_game_bank(text) from public, anon, authenticated;
grant execute on function public.review_accounting_game_question(text,uuid,text,text) to anon, authenticated;
grant execute on function public.insert_accounting_game_questions_bulk(text,jsonb) to anon, authenticated;
grant execute on function public.get_accounting_game_bank(text) to anon, authenticated;
grant execute on function public.start_accounting_game_session() to authenticated;

comment on table public.accounting_game_questions is 'Accounting game question bank with admin approval, learning skill, and IFRS basis metadata.';
comment on column public.accounting_game_questions.standard_basis is 'Accounting basis used to review the teaching content; not a replacement for professional judgement.';
comment on column public.accounting_game_questions.standard_reference is 'Official standard or conceptual-framework reference used by the reviewer.';

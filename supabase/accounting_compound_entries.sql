-- Compound journal entries remain compatible with the existing RPC contract.
-- Multiple accounts are stored in debit_account/credit_account separated by "|".
alter table public.accounting_game_questions add column if not exists entry_type text not null default 'simple';
alter table public.accounting_game_questions drop constraint if exists accounting_game_questions_entry_type_check;
alter table public.accounting_game_questions add constraint accounting_game_questions_entry_type_check check (entry_type in ('simple','compound'));
update public.accounting_game_questions set entry_type=case when position('|' in debit_account)>0 or position('|' in credit_account)>0 then 'compound' else 'simple' end;

create or replace function public.insert_accounting_game_questions_bulk(p_passphrase text default null,p_questions jsonb default '[]'::jsonb)
returns integer language plpgsql security definer set search_path=public,extensions as $$
declare inserted_count int;
begin
  if not public.admin_authorized(p_passphrase) then raise exception 'invalid admin session'; end if;
  if jsonb_array_length(p_questions)>500 then raise exception 'too many questions'; end if;
  insert into public.accounting_game_questions(scenario,debit_account,credit_account,options,explanation,category,difficulty,status,entry_type)
  select left(btrim(q->>'scenario'),500),left(btrim(q->>'debit_account'),120),left(btrim(q->>'credit_account'),120),q->'options',coalesce(q->>'explanation',''),coalesce(nullif(q->>'category',''),'محاسبة مالية'),coalesce(nullif(q->>'difficulty',''),'easy'),coalesce(nullif(q->>'status',''),'active'),case when q->>'entry_type'='compound' or position('|' in q->>'debit_account')>0 or position('|' in q->>'credit_account')>0 then 'compound' else 'simple' end
  from jsonb_array_elements(p_questions) q;
  get diagnostics inserted_count=row_count; return inserted_count;
end; $$;

revoke all on function public.insert_accounting_game_questions_bulk(text,jsonb) from public;
grant execute on function public.insert_accounting_game_questions_bulk(text,jsonb) to anon,authenticated;

insert into public.accounting_game_questions(scenario,debit_account,credit_account,options,explanation,category,difficulty,status,entry_type)
select * from (values
('اشترت المنشأة بضاعة بمبلغ 30,000 جنيه، دفعت 10,000 نقدًا والباقي على الحساب.','المشتريات','الصندوق|الموردون','["المشتريات","الصندوق","الموردون","المبيعات","البنك"]'::jsonb,'المشتريات مدينة بالكامل، بينما توزع الدائنية بين الصندوق والموردين.','محاسبة مالية','medium','active','compound'),
('باعت المنشأة بضاعة نقدًا بمبلغ 11,600 جنيه شامل ضريبة قيمة مضافة 14%.','الصندوق','المبيعات|ضريبة القيمة المضافة المستحقة','["الصندوق","المبيعات","ضريبة القيمة المضافة المستحقة","العملاء","المشتريات"]'::jsonb,'الصندوق مدين، ويُثبت صافي المبيعات وضريبة القيمة المضافة في جانب الدائن.','محاسبة مالية','hard','active','compound'),
('دفعت المنشأة مصروفات تشغيلية قدرها 6,000 جنيه: 4,000 من البنك و2,000 نقدًا.','مصروفات تشغيلية','البنك|الصندوق','["مصروفات تشغيلية","البنك","الصندوق","الموردون","الإيرادات"]'::jsonb,'المصروف مدين، والدفع موزع بين البنك والصندوق كحسابين دائنين.','مصروفات','medium','active','compound'),
('استلمت المنشأة 20,000 جنيه من عميل، منها 5,000 تسوية دفعة مقدمة والباقي سدادًا للرصيد.','البنك','العملاء|دفعات مقدمة من العملاء','["البنك","العملاء","دفعات مقدمة من العملاء","المبيعات","الموردون"]'::jsonb,'البنك مدين، ويُوزع الدائن بين تخفيض رصيد العميل وإثبات الدفعة المقدمة.','خزينة وبنوك','hard','active','compound')
) as v(scenario,debit_account,credit_account,options,explanation,category,difficulty,status,entry_type)
where not exists (select 1 from public.accounting_game_questions where entry_type='compound');

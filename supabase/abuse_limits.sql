-- 防止資料庫被灌滿（免費方案 500 MB，滿了整個專案變唯讀）。Run in Supabase → SQL Editor，可重跑。
-- 要在 schema.sql、word_reports.sql 之後執行。word_reports.sql 裡的 report_word() 已經是同一版，
-- 所以之後重跑 word_reports.sql 也不會把上限拿掉。
--
-- 1. 分享清單：每人同時最多 10 個沒過期的（過期的每小時自動刪，見 schema.sql 第 4 段）。
--    更新同一個代碼（再分享一次）不算新增，不受影響。
create or replace function public.shared_list_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- 同一個人同時建兩個時排隊數，免得一起擠過上限
  perform pg_advisory_xact_lock(hashtext('shared_lists:' || new.owner::text));
  if (select count(*) from shared_lists where owner = new.owner and expires_at > now()) >= 10 then
    raise exception '分享清單最多 10 個，請先到「我的分享」刪掉不用的，或等舊的 72 小時過期';
  end if;
  return new;
end $$;
revoke all on function public.shared_list_limit() from public, anon, authenticated;
drop trigger if exists shared_list_limit on public.shared_lists;
create trigger shared_list_limit before insert on public.shared_lists
  for each row execute function public.shared_list_limit();

-- 2. 單字回報：每台裝置（登入的也算帳號）每天 30 則；沒登入的全部加起來每小時 200 則。
--    超過回傳 'limited'，App 會當作送出、從待送清單拿掉，不會一直重送。
create index if not exists word_reports_device_day on public.word_reports (device, created_at);
create index if not exists word_reports_user_day on public.word_reports (user_id, created_at);
create index if not exists word_reports_created on public.word_reports (created_at);

create or replace function public.report_word(
  p_client_id uuid, p_word text, p_exam_ref text, p_kind text, p_note text, p_snapshot jsonb,
  p_app_version text, p_platform text, p_device text
) returns text
language plpgsql security definer set search_path = public as $$
declare
  who uuid := auth.uid();
  today timestamptz := date_trunc('day', now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
begin
  if p_word is null and p_exam_ref is null then raise exception '沒有要回報的單字或題目'; end if;
  if exists (select 1 from word_reports where client_id = p_client_id) then return 'duplicate'; end if;
  if exists (
    select 1 from word_reports r
    where r.kind = p_kind
      and r.word is not distinct from lower(p_word) and r.exam_ref is not distinct from p_exam_ref
      and r.created_at >= today
      and (case when who is not null then r.user_id = who else r.user_id is null and r.device = p_device end)
  ) then return 'duplicate'; end if;
  if (select count(*) from word_reports r
      where r.created_at >= today
        and ((who is not null and r.user_id = who) or (p_device is not null and r.device = p_device))) >= 30
  then return 'limited'; end if;
  if who is null and (select count(*) from word_reports r
                      where r.user_id is null and r.created_at >= now() - interval '1 hour') >= 200
  then return 'limited'; end if;
  insert into word_reports (user_id, device, client_id, word, exam_ref, kind, note, snapshot, app_version, platform)
  values (who, p_device, p_client_id, lower(p_word), p_exam_ref, p_kind, nullif(trim(p_note), ''),
          coalesce(p_snapshot, '{}'::jsonb), p_app_version, p_platform);
  return 'ok';
end $$;
revoke all on function public.report_word(uuid, text, text, text, text, jsonb, text, text, text) from public;
grant execute on function public.report_word(uuid, text, text, text, text, jsonb, text, text, text) to anon, authenticated;

-- 3. 檢查：兩個都要是 true
select
  exists (select 1 from pg_trigger where tgname = 'shared_list_limit' and not tgisinternal) as share_limit_on,
  position('limited' in pg_get_functiondef('public.report_word(uuid, text, text, text, text, jsonb, text, text, text)'::regprocedure)) > 0 as report_limit_on;

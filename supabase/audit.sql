-- 資料庫異動紀錄：誰（帳號、角色、IP）在什麼時候新增、修改或刪除了哪張表的哪一列。
-- 只記「哪一列、改了哪些欄位」，不存內容，省空間也不會多一份個資。
-- 看紀錄：Table Editor → schema「管理」→「異動紀錄」；可疑的在「可疑異動」。
-- 紀錄保留 30 天（cloud_cleanup 每天清）。在 SQL Editor 執行整個檔案；重跑沒關係。
--
-- 不記的表：電腦玩家積分、配對佇列、每題作答、單字和段位統計（遊戲本身每秒都在改，量太大）；
-- battle_matches 只記新增和刪除（對戰進行中會一直更新狀態）。

create table if not exists 管理.audit_log (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  tbl      text not null,
  op       text not null,            -- INSERT / UPDATE / DELETE
  user_id  uuid,                     -- 呼叫的帳號（auth.uid()）；後台或排程是 null
  role     text,                     -- anon / authenticated / service_role / postgres（後台）
  db_user  text,                     -- 實際寫入的資料庫角色：App 走函式時是函式擁有者，直接打 REST 寫表才是 anon／authenticated
  ip       text,
  row_key  text,                     -- 那一列的 id、user_id 或代碼
  changed  text[]                    -- UPDATE 改到的欄位
);
alter table 管理.audit_log add column if not exists db_user text;
create index if not exists audit_log_at on 管理.audit_log (at desc);
revoke all on 管理.audit_log from public, anon, authenticated;
revoke all on sequence 管理.audit_log_id_seq from public, anon, authenticated;

-- 寫入用：security definer，一般角色碰不到 audit_log 也寫得進去
create or replace function 管理.audit_write(p_tbl text, p_op text, p_db_user text, p_key text, p_cols text[]) returns void
language plpgsql security definer set search_path = public as $$
declare
  claims jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  headers jsonb := nullif(current_setting('request.headers', true), '')::jsonb;
begin
  insert into 管理.audit_log (tbl, op, user_id, role, db_user, ip, row_key, changed)
  values (p_tbl, p_op, nullif(claims->>'sub', '')::uuid, coalesce(claims->>'role', p_db_user), p_db_user,
          nullif(split_part(coalesce(headers->>'x-forwarded-for', headers->>'x-real-ip', ''), ',', 1), ''),
          p_key, p_cols);
end $$;

-- 觸發器本身不是 security definer，才看得到實際寫入的角色（current_user）。
-- 出任何錯都不擋原本的寫入：紀錄寫不進去，App 照常運作。
create or replace function 管理.audit() returns trigger
language plpgsql as $$
declare
  o jsonb;
  n jsonb;
  r jsonb;
  cols text[];
begin
  o := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r := coalesce(n, o);
  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into cols from jsonb_each(n) e(k, v) where o->k is distinct from v;
    -- 只是更新時間或「最後上線」就不記
    if cols is null or cols <@ array['updated_at', 'last_seen', 'seen_at'] then return null; end if;
  end if;
  perform 管理.audit_write(tg_table_schema || '.' || tg_table_name, tg_op, current_user::text,
                          coalesce(r->>'id', r->>'code', r->>'user_id', r->>'term', r->>'name'), cols);
  return null;
exception when others then
  return null;
end $$;

grant usage on schema 管理 to anon, authenticated, service_role, supabase_auth_admin;
revoke all on function 管理.audit_write(text, text, text, text, text[]) from public;
grant execute on function 管理.audit_write(text, text, text, text, text[]) to anon, authenticated, service_role, supabase_auth_admin;

do $$
declare t text;
begin
  foreach t in array array[
    'ai_usage', 'battle_badges', 'battle_banned_words', 'battle_blocks', 'battle_bot_removed', 'battle_friends',
    'battle_invites', 'battle_locked_names', 'battle_players', 'battle_ratings', 'battle_rules', 'battle_snapshots',
    'battle_unlimited', 'battle_words', 'books', 'dev_builds', 'dev_reports', 'dev_testers', 'entitlements', 'lessons',
    'nickname_reports', 'pages', 'promo_campaigns', 'promo_claims', 'promo_codes', 'promo_hits', 'shared_lists',
    'user_backups', 'user_subscriptions', 'word_reports']
  loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop trigger if exists audit on public.%I', t);
    execute format('create trigger audit after insert or update or delete on public.%I for each row execute function 管理.audit()', t);
  end loop;
end $$;

drop trigger if exists audit on public.battle_matches;
create trigger audit after insert or delete on public.battle_matches for each row execute function 管理.audit();

-- 新註冊和刪除的帳號
drop trigger if exists juango_audit on auth.users;
create trigger juango_audit after insert or delete on auth.users for each row execute function 管理.audit();

-- 中文檢視表
create or replace view 管理.異動紀錄 as
select a.at                       as "時間",
       a.tbl                      as "資料表",
       case a.op when 'INSERT' then '新增' when 'UPDATE' then '修改' else '刪除' end as "動作",
       coalesce(upper(p.pid), case when a.user_id is null then null else '（沒有對戰資料）' end) as "使用者 ID",
       p.name                     as "暱稱",
       case a.role when 'anon' then '沒登入' when 'authenticated' then '登入的使用者'
                   when 'service_role' then '伺服器金鑰' else '後台／排程（' || a.role || '）' end as "身分",
       a.ip                       as "IP",
       a.row_key                  as "哪一列",
       array_to_string(a.changed, '、') as "改了哪些欄位"
from 管理.audit_log a
left join public.battle_players p on p.user_id = a.user_id
order by a.at desc;

-- 可疑異動：照 App 的設計不該發生的事
--  · 沒登入的人改了單字回報以外的東西
--  · 不經過函式、直接寫 Pro、開發帳號、方案、兌換碼、對戰不限場、規則、單字庫（這些只有後台和伺服器函式能改，
--    出現就表示權限有漏洞）
--  · 用伺服器金鑰（service_role）改東西：App 和網站都沒有這把，出現就表示金鑰外流
--  · 一個帳號或 IP 在 10 分鐘內改超過 200 次
create or replace view 管理.可疑異動 as
with base as (
  select a.*, case
    when a.role = 'anon' and a.tbl <> 'public.word_reports' then '沒登入卻改了資料'
    when a.db_user in ('anon', 'authenticated') and a.tbl in ('public.entitlements', 'public.dev_testers',
         'public.user_subscriptions', 'public.promo_codes', 'public.promo_campaigns', 'public.promo_claims',
         'public.battle_unlimited', 'public.battle_rules', 'public.battle_words', 'public.battle_banned_words',
         'public.dev_builds', 'public.battle_ratings', 'public.battle_players')
         then '直接改了只有後台和伺服器函式能改的表'
    when a.role = 'service_role' then '用了伺服器金鑰'
  end as reason
  from 管理.audit_log a
),
burst as (
  select coalesce(user_id::text, ip) who, date_trunc('minute', at) - (extract(minute from at)::int % 10) * interval '1 minute' slot, count(*) n
  from 管理.audit_log where coalesce(user_id::text, ip) <> '' group by 1, 2 having count(*) > 200
)
select b.at as "時間", b.reason as "原因", b.tbl as "資料表",
       case b.op when 'INSERT' then '新增' when 'UPDATE' then '修改' else '刪除' end as "動作",
       upper(p.pid) as "使用者 ID", p.name as "暱稱", b.role as "身分", b.ip as "IP", b.row_key as "哪一列"
from base b left join public.battle_players p on p.user_id = b.user_id
where b.reason is not null
union all
select s.slot, '10 分鐘內改了 ' || s.n || ' 次', null, null, upper(p.pid), p.name, null,
       case when p.user_id is null then s.who end, null
from burst s left join public.battle_players p on p.user_id::text = s.who
order by 1 desc;

revoke all on all tables in schema 管理 from public, anon, authenticated;

comment on table 管理.audit_log is '資料庫異動紀錄（只記哪一列、改了哪些欄位，不存內容），保留 30 天';

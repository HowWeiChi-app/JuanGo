-- 資料庫整理和中文閱讀用的檢視表。在 SQL Editor 執行整個檔案；重跑沒關係。
--
-- 1. 刪掉沒在用的東西：一次性下載連結（dev_links、dev_link_new、dev_link_use，改用 GitHub Releases
--    和 App 內更新）、沒人呼叫的函式（ai_left、battle_room_invited）、超過一天的對戰邀請。
-- 2. 「管理」schema：欄位都是中文的檢視表，一眼看出是誰。只給 Supabase 後台（postgres）看，
--    App 和網站的 API 讀不到（不在 API 開放的 schema 裡，也收回了權限）。
--    在 Table Editor 左上角的 schema 選單選「管理」就看得到。
-- 3. 每張表和欄位的中文說明（Table Editor 的欄位說明會顯示）。
-- 4. 省空間：每天清一次舊資料（cloud_cleanup）。
--
-- 實際的表和欄位名稱還是英文：App 是照這些名稱讀寫的，改名 App 就會壞。

-- ------------------------------------------------------------------ 1. 清掉沒在用的
drop function if exists public.dev_link_new(text);
drop function if exists public.dev_link_use(text);
drop table if exists public.dev_links;
drop function if exists public.ai_left(int);
drop function if exists public.battle_room_invited(uuid);
delete from public.battle_invites where created_at < now() - interval '1 day';

-- 4. 每天 04:41 清舊資料。對戰的作答明細（battle_rounds）佔最多空間，但伺服器只用最近的作答
--    （電腦玩家的強度看每級最近 300 題、每人最近 5 題），所以結束超過 60 天的對戰只留比分，
--    作答明細刪掉，最新的 3000 題一定保留。過期的邀請和沒人在等的配對也清掉。
create or replace function public.cloud_cleanup() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from battle_rounds r using battle_matches m
   where m.id = r.match_id and m.finished_at < now() - interval '60 days'
     and (r.match_id, r.n) not in (select match_id, n from battle_rounds order by closed_at desc nulls last limit 3000);
  delete from battle_invites where created_at < now() - interval '1 day';
  delete from battle_queue where last_seen < now() - interval '1 hour';
  -- 異動紀錄（audit.sql）留 30 天
  if to_regclass('管理.audit_log') is not null then
    execute 'delete from 管理.audit_log where at < now() - interval ''30 days''';
  end if;
end $$;
revoke all on function public.cloud_cleanup() from public, anon, authenticated;
select cron.unschedule('cloud-cleanup') where exists (select 1 from cron.job where jobname = 'cloud-cleanup');
select cron.schedule('cloud-cleanup', '41 20 * * *', 'select public.cloud_cleanup()');

-- ------------------------------------------------------------------ 2. 中文檢視表
create schema if not exists 管理;
revoke all on schema 管理 from public;  -- 表和檢視表另外對 anon、authenticated 收回；usage 留給 audit.sql 的紀錄函式

create or replace view 管理.使用者 as
select upper(p.pid)                                  as "ID",
       u.email                                       as "Email",
       p.name                                        as "暱稱",
       t.note                                        as "內測名稱",
       (t.user_id is not null)                       as "開發帳號",
       case when public.gos_pro_expires_at(u.id) is not null then 'GOs PRO'
            when public.juango_pro_expires_at(u.id) is not null then '捲字 Pro' end as "Pro",
       greatest(public.gos_pro_expires_at(u.id), public.juango_pro_expires_at(u.id)) as "Pro 到期",
       p.placed_level                                as "程度測驗",
       r.rating                                      as "本季積分",
       r.games                                       as "本季場數",
       (bu.user_id is not null)                      as "對戰不限場",
       b.updated_at                                  as "最後備份",
       u.last_sign_in_at                             as "最後登入",
       u.created_at                                  as "註冊時間",
       u.id                                          as "user_id"
from auth.users u
left join public.battle_players p   on p.user_id = u.id
left join public.dev_testers t      on t.user_id = u.id
left join public.battle_unlimited bu on bu.user_id = u.id
left join public.user_backups b     on b.user_id = u.id
left join public.battle_ratings r   on r.user_id = u.id and r.season = public.battle_season()
order by u.created_at;

create or replace view 管理.對戰紀錄 as
select m.created_at                                  as "開始時間",
       m.season                                      as "賽季",
       case when m.rated then '排位' else '房間' end  as "類型",
       coalesce(a.name, '?')                         as "玩家一",
       coalesce(b.name, m.bot_name, '?')             as "玩家二",
       m.p1_score                                    as "玩家一分數",
       m.p2_score                                    as "玩家二分數",
       case when m.winner is null then '平手或未結束'
            when m.winner = m.p1 then a.name else coalesce(b.name, m.bot_name) end as "勝者",
       m.p1_delta                                    as "玩家一積分變化",
       m.p2_delta                                    as "玩家二積分變化",
       m.status                                      as "狀態",
       m.reason                                      as "結束原因",
       m.code                                        as "房間代碼",
       m.id                                          as "match_id"
from public.battle_matches m
left join public.battle_players a on a.user_id = m.p1
left join public.battle_players b on b.user_id = m.p2
order by m.created_at desc;

create or replace view 管理.單字回報 as
select w.created_at as "時間", upper(p.pid) as "ID", p.name as "暱稱", w.word as "單字", w.kind as "類型",
       w.note as "說明", w.status as "狀態", w.platform as "平台", w.app_version as "App 版本", w.id as "id"
from public.word_reports w left join public.battle_players p on p.user_id = w.user_id
order by w.created_at desc;

create or replace view 管理.問題回報 as
select d.created_at as "時間", upper(p.pid) as "ID", p.name as "暱稱", d.platform as "平台",
       d.version as "版本", d.build as "Build", d.device as "裝置", d.message as "說明", d.id as "id"
from public.dev_reports d left join public.battle_players p on p.user_id = d.user_id
order by d.created_at desc;

create or replace view 管理.方案 as
select upper(p.pid) as "ID", u.email as "Email", p.name as "暱稱", e.entitlement as "方案", e.source as "來源",
       e.status as "狀態", e.expires_at as "到期", e.updated_at as "更新時間"
from public.entitlements e join auth.users u on u.id = e.user_id left join public.battle_players p on p.user_id = e.user_id
order by e.updated_at desc;

create or replace view 管理.課文書架 as
select upper(p.pid) as "ID", p.name as "暱稱", bk.title as "書名", bk.subject as "科目",
       (select count(*) from public.lessons l where l.book_id = bk.id and l.deleted_at is null) as "課數",
       bk.updated_at as "更新時間", bk.deleted_at as "刪除時間"
from public.books bk left join public.battle_players p on p.user_id = bk.user_id
order by bk.updated_at desc;

grant usage on schema 管理 to postgres;
revoke all on all tables in schema 管理 from public, anon, authenticated;

-- ------------------------------------------------------------------ 3. 中文說明
do $$
declare r record;
begin
  for r in select * from (values
    ('ai_usage', null, '雲端 AI 每月用量'),
    ('ai_usage', 'month', '月份（台灣時間 YYYY-MM）'), ('ai_usage', 'calls', '這個月用了幾次'),
    ('battle_badges', null, '賽季結束時拿到的段位徽章'),
    ('battle_badges', 'season', '賽季'), ('battle_badges', 'tier', '段位編號'), ('battle_badges', 'name', '段位名稱'),
    ('battle_banned_words', null, '暱稱不能用的字'),
    ('battle_blocks', null, '封鎖名單'),
    ('battle_blocks', 'blocker', '按封鎖的人'), ('battle_blocks', 'blocked', '被封鎖的人'), ('battle_blocks', 'bot_name', '被封鎖的電腦玩家'),
    ('battle_bot_ratings', null, '電腦玩家每季的積分'),
    ('battle_bot_removed', null, '已移除的電腦玩家名字'),
    ('battle_bot_resets', null, '一次性重設的紀錄（SQL 檔用來避免重跑；不要刪）'),
    ('battle_bot_sim_days', null, '電腦玩家每天模擬對戰的進度'),
    ('battle_friends', null, '好友'),
    ('battle_friends', 'friend_id', '好友的 user_id'),
    ('battle_invites', null, '房間邀請（超過一天會被清掉）'),
    ('battle_invites', 'from_user', '邀請人'), ('battle_invites', 'to_user', '被邀請的人'),
    ('battle_locked_names', null, '被檢舉而鎖住的暱稱'),
    ('battle_matches', null, '對戰（排位和房間）。中文版見 管理.對戰紀錄'),
    ('battle_matches', 'p1', '玩家一'), ('battle_matches', 'p2', '玩家二（電腦時是空的）'), ('battle_matches', 'winner', '勝者'),
    ('battle_matches', 'rated', '是不是排位賽'), ('battle_matches', 'status', '狀態'), ('battle_matches', 'reason', '結束原因'),
    ('battle_matches', 'p1_delta', '玩家一積分變化'), ('battle_matches', 'p2_delta', '玩家二積分變化'), ('battle_matches', 'code', '房間代碼'),
    ('battle_players', null, '對戰玩家（每個登入過的人一列）。中文版見 管理.使用者'),
    ('battle_players', 'name', '暱稱'), ('battle_players', 'pid', '使用者 ID／好友代碼（App 顯示大寫）'),
    ('battle_players', 'placed_level', '18 題程度測驗的結果（1-6，空的 = 還沒測）'),
    ('battle_players', 'retest', '開發者要他重新測程度'), ('battle_players', 'hide_board', '不顯示在排行榜'),
    ('battle_players', 'name_locked', '暱稱被檢舉鎖住'), ('battle_players', 'flagged', '被檢舉次數'),
    ('battle_queue', null, '排位配對中的人'),
    ('battle_ratings', null, '每季積分和戰績'),
    ('battle_ratings', 'season', '賽季'), ('battle_ratings', 'rating', '積分'), ('battle_ratings', 'peak_rating', '最高積分'),
    ('battle_ratings', 'games', '場數'), ('battle_ratings', 'wins', '勝'), ('battle_ratings', 'losses', '敗'), ('battle_ratings', 'draws', '和'),
    ('battle_rounds', null, '每一局的題目和作答'),
    ('battle_rules', null, '對戰規則設定'),
    ('battle_snapshots', null, '每天的積分分布'),
    ('battle_tier_stats', null, '各段位的平均答對率和速度'),
    ('battle_unlimited', null, '對戰不限場次的測試帳號'),
    ('battle_word_stats', null, '各段位每個字的答對率'),
    ('battle_words', null, '對戰題庫'),
    ('books', null, '課文書架的書'),
    ('dev_builds', null, 'Android 開發版內測安裝檔（舊的開發版 App 從這裡抓更新）'),
    ('dev_reports', null, '開發帳號從 App 送出的問題回報。中文版見 管理.問題回報'),
    ('dev_testers', null, '開發帳號名單：在這裡的人登入後打開開發帳號（GOs PRO、開發者選項）'),
    ('dev_testers', 'note', '名字（自己看的）'),
    ('entitlements', null, '兌換碼、活動送的 Pro。中文版見 管理.方案'),
    ('entitlements', 'entitlement', '方案（juango_pro／gos_pro）'), ('entitlements', 'source', '來源'),
    ('entitlements', 'status', '狀態'), ('entitlements', 'expires_at', '到期時間'),
    ('lessons', null, '課文書架的課'),
    ('nickname_reports', null, '暱稱檢舉'),
    ('pages', null, '課文書架的頁'),
    ('promo_campaigns', null, '「發一篇文，免費用一年」活動'),
    ('promo_claims', null, '活動申請'),
    ('promo_codes', null, '活動兌換碼'),
    ('promo_hits', null, '活動頁防洗版紀錄'),
    ('shared_lists', null, '8 碼分享代碼的單字清單'),
    ('user_backups', null, '雲端同步的資料（單字、進度、清單）'),
    ('user_backups', 'data', '整份備份（JSON）'), ('user_backups', 'updated_at', '最後同步時間'),
    ('user_subscriptions', null, '商店的訂閱和購買'),
    ('word_reports', null, '單字問題回報。中文版見 管理.單字回報')
  ) v(t, c, txt) loop
    if to_regclass('public.' || r.t) is null then continue; end if;
    if r.c is null then
      execute format('comment on table public.%I is %L', r.t, r.txt);
    elsif exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = r.t and column_name = r.c) then
      execute format('comment on column public.%I.%I is %L', r.t, r.c, r.txt);
    end if;
  end loop;
  -- 每張表都有的欄位
  for r in select table_name t, column_name c from information_schema.columns
           where table_schema = 'public' and column_name in ('user_id', 'created_at', 'updated_at', 'deleted_at')
             and table_name in (select tablename from pg_tables where schemaname = 'public') loop
    execute format('comment on column public.%I.%I is %L', r.t, r.c,
      case r.c when 'user_id' then '使用者（auth.users 的 id；是誰請看 管理.使用者）'
               when 'created_at' then '建立時間' when 'updated_at' then '更新時間' else '刪除時間（空的 = 還在）' end);
  end loop;
end $$;

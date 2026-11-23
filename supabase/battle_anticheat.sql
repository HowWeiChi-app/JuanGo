-- 對戰外掛偵測。battle_finish（battle_ranked.sql）在每場排位賽結束時檢查：
--   10 題裡有 8 題以上在 1.2 秒內答對 → 疑似外掛（一般人看題目加選答案大多要 2～5 秒）
--   · 這場雙方都不計分，也不拿來調整電腦對手和表現分的平均
--   · 記一筆到 battle_bot_flags：會出現在「管理 › 可疑異動」，也會寄 email 通知
--   · 7 天內被記 3 次 → battle_players.ranked_locked，不能再配排位賽（房間對戰照常）
-- 誤判要解除：update public.battle_players set ranked_locked = false where pid = lower('使用者ID');
-- 在 SQL Editor 執行整個檔案；重跑沒關係。要在 audit.sql 之後執行（用到 管理.audit）。

alter table public.battle_players add column if not exists ranked_locked boolean not null default false;

create table if not exists public.battle_bot_flags (
  id       bigserial primary key,
  user_id  uuid not null references auth.users on delete cascade,
  match_id uuid,                       -- 對戰刪掉後還留著紀錄
  at       timestamptz not null default now(),
  quick    int not null,               -- 1.2 秒內答對的題數
  avg_ms   int not null                -- 這場平均作答時間
);
create index if not exists battle_bot_flags_user on public.battle_bot_flags (user_id, at desc);
alter table public.battle_bot_flags enable row level security;   -- 沒有任何 policy：App 讀不到
revoke all on public.battle_bot_flags from anon, authenticated;

create or replace function public.battle_flag_bot(p_user uuid, p_match uuid, p_quick int, p_ms int) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into battle_bot_flags (user_id, match_id, quick, avg_ms) values (p_user, p_match, p_quick, p_ms);
  update battle_players set flagged = flagged + 1,
    ranked_locked = ranked_locked or (select count(*) >= 3 from battle_bot_flags
                                      where user_id = p_user and at > now() - interval '7 days')
  where user_id = p_user;
end $$;
revoke all on function public.battle_flag_bot(uuid, uuid, int, int) from public, anon, authenticated;

drop trigger if exists audit on public.battle_bot_flags;
create trigger audit after insert or update or delete on public.battle_bot_flags for each row execute function 管理.audit();

-- 中文檢視表：誰被抓到幾次、有沒有被暫停
create or replace view 管理.外掛偵測 as
select f.at          as "時間",
       upper(p.pid)  as "使用者 ID",
       p.name        as "暱稱",
       f.quick       as "1.2 秒內答對題數",
       f.avg_ms      as "平均作答毫秒",
       (select count(*) from public.battle_bot_flags g where g.user_id = f.user_id and g.at > now() - interval '7 days') as "7 天內次數",
       p.ranked_locked as "排位賽已暫停",
       f.match_id    as "對戰"
from public.battle_bot_flags f
left join public.battle_players p on p.user_id = f.user_id
order by f.at desc;
revoke all on 管理.外掛偵測 from public, anon, authenticated;

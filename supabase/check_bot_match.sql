-- 唯讀檢查（只有 select，不會改任何資料）：排位賽配到的電腦分數為什麼差很多
-- 在 Supabase SQL Editor 貼上執行，把三個結果表貼回來

-- 1. 資料庫裡現在是哪一版函式（true＝battle_social.sql 的新版；false＝被重跑 battle_ranked.sql 蓋回舊版）
select
  (select bool_or(position('battle_float_names' in prosrc) > 0) from pg_proc
    where proname = 'battle_bot_name' and pronamespace = 'public'::regnamespace) as bot_name_picks_nearest,
  (select bool_or(position('battle_human_avg' in prosrc) > 0) from pg_proc
    where proname = 'battle_bot_target' and pronamespace = 'public'::regnamespace) as bot_target_new,
  (select bool_or(position('battle_season_pool' in prosrc) > 0) from pg_proc
    where proname = 'battle_board_season' and pronamespace = 'public'::regnamespace) as leaderboard_has_bots,
  exists (select 1 from pg_trigger where tgname = 'battle_bot_match_rating') as rating_trigger_on;

-- 2. 最近 30 場電腦排位賽：電腦顯示的積分和玩家現在積分差多少、配到的是名單電腦還是浮動電腦
select m.created_at at time zone 'Asia/Taipei' as 台北時間, p.name as 玩家, r.rating as 玩家現在積分,
       m.bot_name as 電腦, m.bot_rating as 電腦積分, m.bot_rating - r.rating as 差距,
       case when m.bot_name = public.battle_boss_name() then '霸王'
            when m.bot_name = any(public.battle_bot_names()) then '名單'
            else '浮動' end as 種類,
       m.winner = m.p1 as 玩家贏, m.reason
from public.battle_matches m
join public.battle_players p on p.user_id = m.p1
left join public.battle_ratings r on r.user_id = m.p1 and r.season = coalesce(m.season, public.battle_season())
where m.rated and m.p2 is null and m.code is null and m.bot_name is not null
order by m.created_at desc limit 30;

-- 3. 差距分布：每天電腦排位賽差距超過 100 分的比例（舊版函式會隨機挑，比例會很高）
select (m.created_at at time zone 'Asia/Taipei')::date as 日期, count(*) as 場數,
       count(*) filter (where abs(m.bot_rating - r.rating) > 100) as 差超過100,
       round(avg(abs(m.bot_rating - r.rating))) as 平均差距
from public.battle_matches m
left join public.battle_ratings r on r.user_id = m.p1 and r.season = coalesce(m.season, public.battle_season())
where m.rated and m.p2 is null and m.code is null and m.bot_name is not null
  and m.created_at > now() - interval '7 days'
group by 1 order by 1 desc;

-- 4. （單獨選取這段執行）改用「比賽當時」的玩家積分：現在積分 − 這場和之後所有已計分場次的加減分
--    差距超過 100 的才是真的配太遠；種類＝浮動／霸王的照設計只會差 30／50 以內
with bm as (
  select m.id, m.created_at, m.p1, m.bot_name, m.bot_rating, coalesce(m.season, public.battle_season()) as season
  from public.battle_matches m
  where m.rated and m.p2 is null and m.code is null and m.bot_name is not null
    and m.created_at > now() - interval '7 days'
), at_time as (
  select bm.*, r.rating - coalesce((
      select sum(case when x.p1 = bm.p1 then x.p1_delta else x.p2_delta end)
      from public.battle_matches x
      where bm.p1 in (x.p1, x.p2) and x.rated and x.status = 'finished'
        and coalesce(x.season, public.battle_season()) = bm.season and x.created_at >= bm.created_at), 0) as 當時積分
  from bm left join public.battle_ratings r on r.user_id = bm.p1 and r.season = bm.season
)
select created_at at time zone 'Asia/Taipei' as 台北時間, bot_name as 電腦, bot_rating as 電腦積分, 當時積分,
       bot_rating - 當時積分 as 差距,
       case when bot_name = public.battle_boss_name() then '霸王'
            when bot_name = any(public.battle_bot_names()) then '名單' else '浮動' end as 種類
from at_time
where abs(bot_rating - 當時積分) > 40
order by abs(bot_rating - 當時積分) desc;

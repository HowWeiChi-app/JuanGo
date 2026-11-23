-- 唯讀檢查（只有 select，不會改任何資料）：看賽季排行最高分的是電腦還是真人、電腦的分數和隱藏實力差多少
-- 在 Supabase SQL Editor 貼上執行，把三個結果表貼回來

-- 1. 電腦積分前 10 名：積分、隱藏實力、場數、勝率（不含平手）
select name, rating, strength, rating - strength as diff, games, sim_games, real_games, wins, losses, draws,
       round(wins::numeric / nullif(games, 0), 3) as win_rate,
       round(wins::numeric / nullif(wins + losses, 0), 3) as win_rate_no_draw
from public.battle_bot_ratings where season = public.battle_season()
order by rating desc limit 10;

-- 2. 真人積分前 10 名
select p.name, r.rating, r.games, r.wins, r.losses, r.draws,
       round(r.wins::numeric / nullif(r.games, 0), 3) as win_rate
from public.battle_ratings r join public.battle_players p on p.user_id = r.user_id
where r.season = public.battle_season()
order by r.rating desc limit 10;

-- 3. 全部電腦的平均積分、平均隱藏實力、互打進度
select count(*) as bots, round(avg(rating)) as avg_rating, round(avg(strength)) as avg_strength,
       min(rating) as min_rating, max(rating) as max_rating, max(strength) as max_strength,
       sum(sim_games) / 2 as sim_matches, count(*) filter (where rating <= 600) as at_floor
from public.battle_bot_ratings where season = public.battle_season();

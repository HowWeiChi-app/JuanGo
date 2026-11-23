-- DC-42B9E8D9：電腦互打改成每天全天 14400 場（平均每分鐘 10 場）。可以重跑。
-- 只改 battle_bot_sim_days 的預設值和今天起的列，不用跑整份 battle_social.sql。在 Supabase SQL Editor 貼上整份執行。
-- 排程照舊每分鐘叫 battle_bot_sim_cron()：把剩下的場數平均分到剩下的分鐘，全天 1440 分鐘 → 每分鐘 10 場。
-- 今天（執行當天）已經打過的場數會保留，剩下的場數分到今天剩下的分鐘，所以今天每分鐘會比 10 場多一些；明天起就是每分鐘 10 場。

alter table public.battle_bot_sim_days alter column target set default 14400;
alter table public.battle_bot_sim_days alter column from_t set default '00:00';
alter table public.battle_bot_sim_days alter column until_t set default '23:59:59';

update public.battle_bot_sim_days set target = 14400, from_t = '00:00', until_t = '23:59:59'
where day >= public.battle_local()::date and not asap;

-- 檢查：今天的設定、已打場數，以及排程還在
select d.day, d.target, d.from_t, d.until_t, d.asap, d.played,
       exists (select 1 from cron.job where jobname = 'battle-bot-sim' and schedule = '* * * * *') as cron_every_minute
from public.battle_bot_sim_days d
where d.day = public.battle_local()::date;

-- DC-42B9E8D9：只換掉 battle_bot_name 一個函式（內容和 battle_social.sql 裡的新版相同），可以重跑。
-- 修正：以前只檢查「最接近那台」差不差超過 100，再從最接近的 5 台隨機挑，挑到第 2～5 台時可能差 100 分以上。
-- 現在先排除差距超過 100 的名單電腦，再從最接近的 5 台裡隨機挑；一台都沒有才配浮動電腦（玩家積分 ±30）。
-- 不用跑整份 battle_social.sql（那份會重設排程等其他東西）。在 Supabase SQL Editor 貼上整份執行即可。

create or replace function public.battle_bot_name(p_for uuid) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  s text := battle_season();
  r int;
  n text;
begin
  perform battle_bot_seed(s);
  r := coalesce((select rating from battle_ratings where user_id = p_for and season = s), 1200);
  select x.name into n from (
    select b.name from battle_bot_ratings b
    where b.season = s and b.name = any(battle_bot_names())
      and abs(b.rating - r) <= 100
      and not exists (select 1 from battle_players p where lower(p.name) = lower(b.name))
      and not exists (select 1 from battle_bot_removed x where x.name = b.name)
      and not exists (select 1 from battle_blocks k where k.blocker = p_for and k.bot_name = b.name)
    order by abs(b.rating - r) limit 5) x
  order by random() limit 1;
  if n is null then
    select f into n from unnest(battle_float_names()) f
    where not exists (select 1 from battle_players p where lower(p.name) = lower(f))
      and not exists (select 1 from battle_bot_removed x where x.name = f)
      and not exists (select 1 from battle_blocks k where k.blocker = p_for and k.bot_name = f)
    order by random() limit 1;
  end if;
  return n;
end $$;

-- 內部用，App 不能直接呼叫（和 battle_social.sql 相同）
revoke all on function public.battle_bot_name(uuid) from public, anon, authenticated;

-- 檢查：兩個都要是 true
select
  (select bool_and(position('abs(b.rating - r) <= 100' in prosrc) > 0) from pg_proc
    where proname = 'battle_bot_name' and pronamespace = 'public'::regnamespace and pronargs = 1) as bot_name_fixed,
  not has_function_privilege('authenticated', 'public.battle_bot_name(uuid)', 'execute') as bot_name_private;

-- ⚠️ 重跑這個檔之後，一定要依序再跑：battle_social.sql → battle_lobby.sql → subscriptions.sql → battle_grants.sql。
--    這個檔裡的 battle_board／battle_board_season（排行不含電腦）、battle_bot_name、battle_bot_target、battle_bot_ms、
--    battle_join、has_pro 是舊版，後面幾個檔會換成新版；只重跑這個檔，電腦會從排行消失、房間和 Pro 判斷也會變回舊的。
-- JuanGo ranked battles (run after battle.sql and battle_words.sql): 10 questions, tiers, seasons, the computer
-- playing like a player of the tier, the season leaderboard, nickname reports and blocking.
-- The numbers live in supabase/battle_rules.json; the copy below must match it (tools/battle_sim.py checks).

-- ------------------------------------------------------------------ rules

create table if not exists public.battle_rules (
  id    int primary key default 1 check (id = 1),
  rules jsonb not null
);
insert into public.battle_rules (id, rules) values (1, $rules${
  "rounds": 10,
  "round_ms": 10000,
  "reveal_ms": 3000,
  "points": { "correct": 25, "speed": 75, "min_ms": 400 },
  "start_rating": [900, 1000, 1100, 1200, 1300, 1400],
  "min_rating": 600,
  "tiers": [
    { "name": "尊貴鉑金", "from": 0, "bot": 0.70, "win": 28, "loss": 14 },
    { "name": "永恆鑽石", "from": 1100, "bot": 0.75, "win": 25, "loss": 17 },
    { "name": "至尊星耀", "from": 1200, "bot": 0.80, "win": 20, "loss": 20 },
    { "name": "無雙卷哥", "from": 1400, "bot": 0.83, "win": 18, "loss": 22 },
    { "name": "璀璨卷王", "from": 1600, "bot": 0.87, "win": 16, "loss": 24 },
    { "name": "傳奇卷神", "from": 1800, "bot": 0.90, "win": 15, "loss": 25 }
  ],
  "above_top": { "every": 100, "bot_step": 0.01, "win_step": -1, "bot_max": 0.97, "win_min": 5 },
  "opponent": { "per": 50, "max": 8 },
  "performance": { "max": 5, "per_correct": 1.0, "per_second": 1.0, "brave_loss_correct": 8, "weak_win_correct": 5 },
  "streak": { "from": 3, "first": 2, "step": 1, "max": 5 },
  "floor": { "win": 5, "loss": 5 },
  "rookie": { "games": 10, "factor": 1.5, "cap": 300, "until": 1200, "bot_bonus": 0.05, "bot_max": 0.90 },
  "match": { "start": 10, "grow": 10, "grow_s": 10, "wide": 200, "wide_s": 6, "bot_s": [4, 7] },
  "bot": {
    "base_penalty": 3,
    "rating_spread": 30,
    "streak": 3,
    "adjust": 0.10,
    "min": 0.60,
    "max": 0.97,
    "min_samples": 30,
    "level_step": 0.05,
    "speed_ms": [[3000, 6000], [2500, 5500], [2000, 5000], [2000, 4500], [2000, 4000], [1500, 3500]],
    "speed_recent": 5,
    "speed_adjust_ms": 1000
  },
  "pair_daily_ranked": 3,
  "free_daily": 10,
  "leave": { "winner_factor": 0.5 },
  "season": { "close": "23:30", "settle": "23:45" },
  "leaderboard": { "top": 20, "min_games": 60, "live_min_games": 10 }
}$rules$::jsonb)
on conflict (id) do update set rules = excluded.rules;
alter table public.battle_rules enable row level security;

create or replace function public.battle_rules() returns jsonb
language sql stable security definer set search_path = public as $$
  select rules from battle_rules where id = 1
$$;

-- ------------------------------------------------------------------ subscriptions (filled by the RevenueCat webhook)

create table if not exists public.entitlements (
  user_id     uuid not null references auth.users on delete cascade,
  entitlement text not null,
  primary key (user_id, entitlement),
  source      text not null check (source in ('app_store', 'play_store', 'promo')),
  product_id  text,
  status      text not null check (status in ('active', 'grace', 'canceled', 'expired')),
  expires_at  timestamptz not null,
  updated_at  timestamptz not null default now()
);
alter table public.entitlements enable row level security;
drop policy if exists "read own entitlement" on public.entitlements;
create policy "read own entitlement" on public.entitlements for select using (auth.uid() = user_id);

create or replace function public.has_pro(p_user uuid, p_app text default 'juango_pro') returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from entitlements e where e.user_id = p_user and e.entitlement = p_app
                 and e.status in ('active', 'grace', 'canceled') and e.expires_at > now())
$$;

-- ------------------------------------------------------------------ tables

alter table public.battle_rounds drop constraint if exists battle_rounds_n_check;
alter table public.battle_rounds add constraint battle_rounds_n_check check (n between 1 and 10);

alter table public.battle_players add column if not exists pid text;
update public.battle_players set pid = substr(md5(random()::text || user_id::text), 1, 10) where pid is null;
alter table public.battle_players alter column pid set default substr(md5(random()::text), 1, 10);
create unique index if not exists battle_players_pid on public.battle_players (pid);
alter table public.battle_players add column if not exists hide_board boolean not null default false;
alter table public.battle_players add column if not exists name_locked boolean not null default false;
alter table public.battle_players add column if not exists flagged int not null default 0;

alter table public.battle_matches add column if not exists season text;
alter table public.battle_matches add column if not exists note text;          -- pair_limit
alter table public.battle_matches add column if not exists bot_accuracy numeric;
alter table public.battle_matches add column if not exists rematch uuid;
alter table public.battle_matches add column if not exists boss text;          -- the hidden computer's opening line, null otherwise         -- the room match 再來一場 opened
alter table public.battle_matches add column if not exists p1_breakdown jsonb;
alter table public.battle_matches add column if not exists p2_breakdown jsonb;

create table if not exists public.battle_ratings (
  user_id      uuid not null references auth.users on delete cascade,
  season       text not null,
  rating       int not null,
  start_rating int not null,
  peak_rating  int not null,
  games        int not null default 0,
  wins         int not null default 0,
  losses       int not null default 0,
  draws        int not null default 0,
  win_streak   int not null default 0,
  rookie_games int not null default 0,
  rookie_bonus int not null default 0,
  rookie_done  boolean not null default false,
  bot_streak   int not null default 0,      -- wins against the computer in a row (+) or losses (-)
  bot_recent   numeric[] not null default '{}',
  primary key (user_id, season)
);
create index if not exists battle_ratings_board on public.battle_ratings (season, rating desc);

create table if not exists public.battle_badges (
  user_id uuid not null references auth.users on delete cascade,
  season  text not null,
  tier    int not null,
  name    text not null,
  primary key (user_id, season)
);

-- per tier and word: how often players get it right and how long they take (no one's own answers are kept)
create table if not exists public.battle_word_stats (
  tier     int not null,
  word     text not null,
  attempts int not null default 0,
  correct  int not null default 0,
  avg_ms   int,
  primary key (tier, word)
);

-- per tier: how a game usually goes, for the performance points
create table if not exists public.battle_tier_stats (
  tier        int primary key,
  games       int not null default 0,
  avg_correct numeric not null default 7,
  avg_ms      numeric not null default 4500
);

create table if not exists public.battle_snapshots (
  season    text not null,
  day       int not null,
  histogram jsonb not null,               -- {"1200": 31, ...}: players per 10 points
  primary key (season, day)
);

create table if not exists public.battle_blocks (
  id         bigserial primary key,
  blocker    uuid not null references auth.users on delete cascade,
  blocked    uuid references auth.users on delete cascade,  -- null: a computer
  bot_name   text,
  name       text not null,                                 -- the name at the time, for the list
  created_at timestamptz not null default now(),
  check ((blocked is null) <> (bot_name is null))
);
create unique index if not exists battle_blocks_unique on public.battle_blocks (blocker, coalesce(blocked::text, bot_name));

create table if not exists public.nickname_reports (
  id         bigserial primary key,
  reporter   uuid not null references auth.users on delete cascade,
  target     uuid references auth.users on delete cascade,  -- null: a computer
  nickname   text not null,
  reason     text not null check (reason in ('vulgar', 'offensive', 'impersonation', 'other')),
  status     text not null default 'pending' check (status in ('pending', 'locked', 'dismissed', 'confirmed')),
  created_at timestamptz not null default now(),
  unique (reporter, nickname)
);

create table if not exists public.battle_locked_names (name text primary key);
create table if not exists public.battle_bot_removed (name text primary key);
create table if not exists public.battle_banned_words (word text primary key);
insert into public.battle_banned_words (word) values
  ('幹你'), ('幹拎'), ('靠北'), ('靠杯'), ('操你'), ('屌'), ('雞掰'), ('機掰'), ('雞巴'), ('智障'), ('白痴'), ('白癡'),
  ('婊'), ('賤人'), ('去死'), ('屁眼'), ('做愛'), ('色情'), ('性交'), ('陰莖'), ('陰道'), ('他媽'), ('你媽'), ('三小'),
  ('低能'), ('腦殘'), ('垃圾人'), ('fuck'), ('shit'), ('bitch'), ('dick'), ('pussy'), ('cunt'), ('nigg'), ('porn'),
  ('asshole'), ('penis'), ('vagina'), ('sex')
on conflict do nothing;

alter table public.battle_ratings      enable row level security;
alter table public.battle_badges       enable row level security;
alter table public.battle_word_stats   enable row level security;
alter table public.battle_tier_stats   enable row level security;
alter table public.battle_snapshots    enable row level security;
alter table public.battle_blocks       enable row level security;
alter table public.nickname_reports    enable row level security;
alter table public.battle_locked_names enable row level security;
alter table public.battle_bot_removed  enable row level security;
alter table public.battle_banned_words enable row level security;

-- ------------------------------------------------------------------ seasons (Taiwan time; six a year)

create or replace function public.battle_local(t timestamptz default clock_timestamp()) returns timestamp
language sql stable set search_path = public as $$ select t at time zone 'Asia/Taipei' $$;

create or replace function public.battle_season(t timestamptz default clock_timestamp()) returns text
language sql stable set search_path = public as $$
  select to_char(battle_local(t), 'YYYY') || '-S' || ((extract(month from battle_local(t))::int + 1) / 2)
$$;

-- first and last day of a season, e.g. 2026-S6 → 2026-11-01 and 2026-12-31
create or replace function public.battle_season_first(s text) returns date
language sql immutable set search_path = public as $$
  select make_date(split_part(s, '-S', 1)::int, split_part(s, '-S', 2)::int * 2 - 1, 1)
$$;
create or replace function public.battle_season_last(s text) returns date
language sql immutable set search_path = public as $$
  select (battle_season_first(s) + interval '2 months' - interval '1 day')::date
$$;
create or replace function public.battle_season_prev(s text) returns text
language sql immutable set search_path = public as $$
  select battle_season((battle_season_first(s) - 1)::timestamp at time zone 'Asia/Taipei' + interval '12 hours')
$$;
create or replace function public.battle_season_label(s text) returns text
language sql immutable set search_path = public as $$ select replace(s, '-', ' ') $$;

-- open | closing (23:30, no new matches) | settling (23:45, unfinished matches end without points)
create or replace function public.battle_phase(t timestamptz default clock_timestamp()) returns text
language plpgsql stable set search_path = public as $$
declare
  l timestamp := battle_local(t);
  rules jsonb := battle_rules();
begin
  if l::date <> battle_season_last(battle_season(t)) then return 'open'; end if;
  if l::time >= (rules->'season'->>'settle')::time then return 'settling'; end if;
  if l::time >= (rules->'season'->>'close')::time then return 'closing'; end if;
  return 'open';
end $$;

-- ------------------------------------------------------------------ tiers and ratings

create or replace function public.battle_tier_info(r int) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  rules jsonb := battle_rules();
  tiers jsonb := rules->'tiers';
  top   jsonb := rules->'above_top';
  n     int := jsonb_array_length(tiers);
  i     int := 0;
  t     jsonb;
  steps int;
  bot   numeric;
  win   int;
begin
  for k in 0..n - 1 loop
    if r >= (tiers->k->>'from')::int then i := k; end if;
  end loop;
  t := tiers->i;
  bot := (t->>'bot')::numeric;
  win := (t->>'win')::int;
  if i = n - 1 then
    steps := greatest(0, (r - (t->>'from')::int) / (top->>'every')::int);
    bot := least((top->>'bot_max')::numeric, bot + steps * (top->>'bot_step')::numeric);
    win := greatest((top->>'win_min')::int, win + steps * (top->>'win_step')::int);
  end if;
  return jsonb_build_object('index', i + 1, 'name', t->>'name', 'bot', bot, 'win', win, 'loss', (t->>'loss')::int,
    'from', (t->>'from')::int,
    'next', case when i < n - 1 then (tiers->(i + 1)->>'from')::int end,
    'next_name', case when i < n - 1 then tiers->(i + 1)->>'name' end);
end $$;

create or replace function public.battle_tier(r int) returns int
language sql stable set search_path = public as $$ select (battle_tier_info(r)->>'index')::int $$;

create or replace function public.battle_start_rating(p_level int) returns int
language sql stable set search_path = public as $$
  select (battle_rules()->'start_rating'->>(least(6, greatest(1, coalesce(p_level, 3))) - 1))::int
$$;

-- The caller's rating this season. The first time in a season it comes from last season's tier
-- (900 for 尊貴鉑金 … 1400 for 傳奇卷神), or from the level test for a new player.
create or replace function public.battle_rating(p_user uuid) returns public.battle_ratings
language plpgsql security definer set search_path = public as $$
declare
  s    text := battle_season();
  r    public.battle_ratings;
  prev public.battle_ratings;
  lv   int;
  start int;
begin
  select * into r from battle_ratings where user_id = p_user and season = s;
  if found then return r; end if;
  select * into prev from battle_ratings where user_id = p_user and season < s order by season desc limit 1;
  if found then
    start := (battle_rules()->'start_rating'->>(least(6, battle_tier(prev.rating)) - 1))::int;
  else
    select placed_level into lv from battle_players where user_id = p_user;
    start := battle_start_rating(lv);
  end if;
  insert into battle_ratings (user_id, season, rating, start_rating, peak_rating, rookie_done)
  values (p_user, s, start, start, start, prev.user_id is not null or start >= (battle_rules()->'rookie'->>'until')::int)
  on conflict (user_id, season) do nothing;
  select * into r from battle_ratings where user_id = p_user and season = s;
  return r;
end $$;

-- the word level a pair plays at: 900 → 第 1 級, 1200 → 第 4 級, 1400 and up → 第 6 級
create or replace function public.battle_word_level(avg_rating numeric) returns int
language sql immutable set search_path = public as $$
  select least(6, greatest(1, round((avg_rating - 900) / 100.0)::int + 1))
$$;

-- 25 for a right answer and up to 75 more the faster it came; under 0.4 seconds gets no speed points
create or replace function public.battle_points(ms int, right_answer boolean) returns int
language plpgsql stable set search_path = public as $$
declare p jsonb := battle_rules()->'points'; lim int := (battle_rules()->>'round_ms')::int;
begin
  if not right_answer then return 0; end if;
  if ms < (p->>'min_ms')::int then return (p->>'correct')::int; end if;
  return round((p->>'correct')::int + (p->>'speed')::int * (1 - least(greatest(ms, 0), lim)::numeric / lim))::int;
end $$;

-- Test accounts that play without the daily limit (the dev build turns on every Pro feature in the app;
-- this is the server's side of that). Not a subscription, so it stays out of entitlements.
create table if not exists public.battle_unlimited (
  user_id uuid primary key references auth.users on delete cascade,
  note    text,
  created_at timestamptz not null default now()
);
alter table public.battle_unlimited enable row level security;
-- the dev build's 開發者選項 can switch it off for a while, to try the free version's limit
alter table public.battle_unlimited add column if not exists paused boolean not null default false;
-- set by hand in the SQL editor (for recording the hidden computer's entrance): the next computer match is it
alter table public.battle_unlimited add column if not exists boss_next boolean not null default false;

-- 開發者選項 › 單字對戰不限場次. Only changes an existing test account row, so it can't grant anything.
create or replace function public.battle_dev_limit(p_paused boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update battle_unlimited set paused = p_paused where user_id = auth.uid();
  return found;
end $$;

-- the number of ranked matches the caller may still start today, null with Pro (games that don't count are free)
create or replace function public.battle_free_left(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when not exists (select 1 from battle_unlimited u where u.user_id = p_user and u.paused)
              and (has_pro(p_user) or exists (select 1 from battle_unlimited u where u.user_id = p_user)) then null else greatest(0, (battle_rules()->>'free_daily')::int - (
    select count(*) from battle_matches m
    where m.code is null and m.rated and p_user in (m.p1, m.p2) and battle_local(m.created_at)::date = battle_local()::date))::int end
$$;

create or replace function public.battle_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from battle_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;

-- a stable id for a computer name, shaped like a player's, so the apps can't tell them apart
create or replace function public.battle_bot_pid(p_name text) returns text
language sql immutable set search_path = public as $$ select substr(md5('juango-bot:' || p_name), 1, 10) $$;

create or replace function public.battle_bot_names() returns text[]
language sql immutable set search_path = public as $$
  -- names real players pick or never change: the default 形容詞+動物+兩位數, account-style English, nicknames
  select array[
    '勇敢的水獺08','安靜的石虎41','快樂的黑熊17','認真的貓頭鷹63','聰明的海豚29','好奇的藍鵲05','溫柔的穿山甲72','機靈的梅花鹿36','認真的水獺90','快樂的藍鵲24','安靜的海豚58',
    '好奇的石虎13','機靈的黑熊81','溫柔的貓頭鷹47','勇敢的穿山甲66','聰明的梅花鹿02','kevin0812','amy_chen','jason.lin','ethan_wu','chloe1103',
    'ian_huang','vivi_0920','leo.tsai','grace_lai','ryan27','annie.c','max_0505','yuki_tw','eric0716','joyce.h',
    'wendy_yang','alan1029','iris_ko','daniel.lee','sandy0313','yuchen_','tingyu0228','weiting.c','hsuan_0619',
    'pinyu_','yihsuan1107','chiahao_tw','tzuyu.w','po_han','shihyu0901','柚子茶加冰','一條鹹魚','肥宅快樂水','香菜退散','吐司邊','黑糖珍奶','雞排加辣','蘿蔔糕','小籠包控','綠茶無糖','今天吃什麼','窩不知道','數學好難QQ',
    '壞掉的鬧鐘','安安你好','啾咪','起司貓','阿嬤的芭樂','林小柚','陳品妤','王小捲','蕭蕭','歐陽','品品','Ting','Yi',
    'yu._.','chen','莓果優格','芒果冰','咖哩飯','鹽酥雞','豬豬','好想吃火鍋','隔壁的阿明','早餐店奶茶','卷卷','睡不飽','想放假','不想早起','珍奶續命','早八戰士','三分鐘熱度','讀書好累','一直想睡','今天也很累',
    '肚子餓了','zzz','hihi','嗯嗯','好喔','qq','路過','隨便啦']
$$;

-- a computer name nobody uses, that wasn't reported, and that the caller hasn't blocked
-- A hidden computer, 1 in 100 computer matches: 10% more accurate, 10% faster and rated 10% higher.
-- Not part of battle_rules() on purpose, so nothing in the apps describes it.
create or replace function public.battle_boss_name() returns text language sql immutable as $$ select '優質霸王' $$;

create or replace function public.battle_bot_name(p_for uuid) returns text
language sql volatile security definer set search_path = public as $$
  select n from unnest(battle_bot_names()) as n
  where not exists (select 1 from battle_players p where lower(p.name) = lower(n))
    and not exists (select 1 from battle_bot_removed x where x.name = n)
    and not exists (select 1 from battle_blocks b where b.blocker = p_for and b.bot_name = n)
  order by random() limit 1
$$;

create or replace function public.battle_name_problem(p_name text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from battle_banned_words w where position(w.word in lower(p_name)) > 0) then '這個名稱不能使用'
    when exists (select 1 from battle_locked_names l where lower(l.name) = lower(p_name)) then '這個名稱不能使用'
  end
$$;

-- ------------------------------------------------------------------ starting a match

create or replace function public.battle_check_open() returns void
language plpgsql stable set search_path = public as $$
begin
  if battle_phase() <> 'open' then raise exception '今晚賽季結算中，00:00 開放新賽季'; end if;
end $$;

-- How accurate the computer is against this player: its tier's rate, the rookie rate during the first games,
-- or after three wins or losses against it in a row, the player's own average over those three.
create or replace function public.battle_bot_target(p_user uuid) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  rules jsonb := battle_rules();
  b  jsonb := rules->'bot';
  ro jsonb := rules->'rookie';
  r  public.battle_ratings;
  t  jsonb;
  lv int;
  a  numeric;
begin
  select * into r from battle_ratings where user_id = p_user and season = battle_season();
  t := battle_tier_info(r.rating);
  select placed_level into lv from battle_players where user_id = p_user;
  if not r.rookie_done and coalesce(lv, 3) <= 3 then
    return least((ro->>'bot_max')::numeric, (rules->'tiers'->(coalesce(lv, 3) - 1)->>'bot')::numeric + (ro->>'bot_bonus')::numeric);
  end if;
  if abs(r.bot_streak) >= (b->>'streak')::int and coalesce(array_length(r.bot_recent, 1), 0) >= (b->>'streak')::int then
    select avg(x) into a from unnest(r.bot_recent[array_length(r.bot_recent, 1) - (b->>'streak')::int + 1:]) x;
    a := least((t->>'bot')::numeric + (b->>'adjust')::numeric, greatest((t->>'bot')::numeric - (b->>'adjust')::numeric, a));
    return least((b->>'max')::numeric, greatest((b->>'min')::numeric, a));
  end if;
  return (t->>'bot')::numeric;
end $$;

-- Two words clash when a player could fairly pick either: a shared meaning, the same meaning once 使/被/把 and
-- 的/地 are dropped, or one shown meaning inside the other's (二字以上), e.g. 痛苦 / 痛苦的, 興奮的 / 令人興奮的.
create or replace function public.battle_norm(s text) returns text
language sql immutable as $$ select regexp_replace(replace(s, '…', ''), '^(使|被|把)|(的|地)$', '', 'g') $$;

create or replace function public.battle_close(p text, q text) returns boolean
language sql immutable as $$ select length(p) >= 2 and length(q) >= 2 and (strpos(p, q) > 0 or strpos(q, p) > 0) $$;

create or replace function public.battle_clash(a text[], b text[], az text, bz text) returns boolean
language sql immutable as $$
  select a && b
    or exists (select 1 from unnest(a) x, unnest(b) y where battle_norm(x) = battle_norm(y))
    or exists (select 1 from unnest(b) y where battle_close(battle_norm(az), battle_norm(y)))
    or exists (select 1 from unnest(a) x where battle_close(battle_norm(bz), battle_norm(x)))
$$;

create or replace function public.battle_make_round(p_match uuid, p_n int, p_lv int) returns void
language plpgsql security definer set search_path = public as $$
declare
  w     public.battle_words;
  wrong public.battle_words[];
  to_zh boolean := random() < 0.5;
  opts  text[];
  right_text text;
begin
  select * into w from battle_words b
  where b.lv = p_lv and not exists (select 1 from battle_rounds r where r.match_id = p_match and r.term = b.term)
  order by random() limit 1;
  if not found then raise exception '題庫還沒匯入'; end if;
  select array_agg(x) into wrong from (
    select d from (
      select distinct on (c.zh) c as d, c.pos = w.pos as same, random() as k
      from battle_words c
      where c.lv = p_lv and c.term <> w.term and lower(c.term) <> lower(w.term)
        and not battle_clash(w.meanings, c.meanings, w.zh, c.zh)
      order by c.zh, random()
    ) s order by same desc, k limit 3
  ) t(x);
  if coalesce(array_length(wrong, 1), 0) < 3 then raise exception '題庫不足'; end if;
  right_text := case when to_zh then w.zh else w.term end;
  select array_agg(o order by random()) into opts from unnest(
    array[right_text] || array(select case when to_zh then (e).zh else (e).term end from unnest(wrong) e)
  ) o;
  insert into battle_rounds (match_id, n, term, zh, to_zh, prompt, options, answer)
  values (p_match, p_n, w.term, w.zh, to_zh, case when to_zh then w.term else w.zh end, opts,
          array_position(opts, right_text) - 1);
end $$;

-- Ten questions at the word level of the pair's average rating, only English→Chinese and Chinese→English.
-- How long the computer takes on one question: a normal curve over its tier's range (so the middle is most
-- likely), moved by up to a second toward how fast the player answered their last five questions.
create or replace function public.battle_bot_ms(p_user uuid, p_tier int) returns int
language plpgsql security definer set search_path = public as $$
declare
  rules jsonb := battle_rules();
  b   jsonb := rules->'bot';
  rng jsonb := b->'speed_ms'->(least(greatest(p_tier, 1), jsonb_array_length(b->'speed_ms')) - 1);
  lo  numeric := (rng->>0)::numeric;
  hi  numeric := (rng->>1)::numeric;
  mid numeric := (lo + hi) / 2;
  adj numeric := (b->>'speed_adjust_ms')::numeric;
  recent numeric;
  shift numeric := 0;
  x   numeric;
begin
  select avg(coalesce(ms, (rules->>'round_ms')::int)) into recent from (
    select case when mm.p1 = p_user then r.p1_ms else r.p2_ms end as ms
    from battle_rounds r join battle_matches mm on mm.id = r.match_id
    where (mm.p1 = p_user or mm.p2 = p_user) and r.closed_at is not null
    order by r.closed_at desc limit (b->>'speed_recent')::int
  ) q;
  if recent is not null then shift := least(adj, greatest(-adj, recent - mid)); end if;
  -- Box-Muller; the range is ±2 standard deviations, and a draw outside it is drawn again
  for i in 1..10 loop
    x := mid + sqrt(-2 * ln(greatest(random(), 1e-9))) * cos(2 * pi() * random()) * (hi - lo) / 4;
    exit when x between lo and hi;
  end loop;
  return round(least(hi, greatest(lo, x)) + shift)::int;
end $$;

-- Against the computer, which questions it gets right follows how players of the tier do on each word.
create or replace function public.battle_start(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  rules jsonb := battle_rules();
  b     jsonb := rules->'bot';
  m     public.battle_matches;
  t     timestamptz := clock_timestamp();
  n_rounds int := (rules->>'rounds')::int;
  lv    int;
  ptier int;
  plv   int;
  target numeric;
  k     int;
begin
  select * into m from battle_matches where id = p_match for update;
  select battle_word_level(avg(x)) into lv from (
    select (battle_rating(u)).rating as x from unnest(array[m.p1, m.p2]) u where u is not null
    union all select m.bot_rating where m.bot_rating is not null
  ) r;
  for i in 1..n_rounds loop perform battle_make_round(p_match, i, lv); end loop;

  if m.bot_rating is not null then
    target := battle_bot_target(m.p1);
    if m.boss is not null then target := least(0.99, target * 1.1); end if;
    ptier := battle_tier((battle_rating(m.p1)).rating);
    plv := battle_word_level((battle_rating(m.p1)).rating);
    -- how many it gets right: the target over ten questions, give or take one
    k := least(n_rounds, greatest(0, round(target * n_rounds)::int + floor(random() * 3)::int - 1));
    with odds as (
      select r.n, r.answer,
             least(0.99, greatest(0.01, coalesce(
               case when s.attempts >= (b->>'min_samples')::int then s.correct::numeric / s.attempts end,
               target + (b->>'level_step')::numeric * (plv - lv)))) as p,
             s.avg_ms, s.attempts
      from battle_rounds r left join battle_word_stats s on s.tier = ptier and s.word = r.term
      where r.match_id = p_match
    ), picked as (
      select o.*, row_number() over (order by -ln(greatest(random(), 1e-9)) / o.p) <= k as right_one from odds o
    )
    update battle_rounds x set
      bot_pick = case when p.right_one then x.answer else (x.answer + 1 + floor(random() * 3)::int) % 4 end,
      bot_ms = round(battle_bot_ms(m.p1, ptier) * case when m.boss is not null then 0.9 else 1 end)::int
    from picked p where x.match_id = p_match and x.n = p.n;
    update battle_matches set bot_accuracy = target where id = p_match;
  end if;

  -- the hidden computer's entrance (about 4 seconds) plays before the usual 4-second countdown
  update battle_rounds set starts_at = t + case when m.boss is not null then interval '8 seconds' else interval '4 seconds' end,
    ends_at = t + case when m.boss is not null then interval '8 seconds' else interval '4 seconds' end
              + (rules->>'round_ms')::int * interval '1 millisecond'
  where match_id = p_match and n = 1;
  update battle_matches set status = 'playing', round = 1, p1_seen = t, p2_seen = t, season = battle_season(t)
  where id = p_match;
end $$;

-- Looks for an opponent; the app calls this about once a second while waiting. The rating window starts at
-- ±10 and opens by 10 a second for 10 seconds, then ±200 for 6 seconds; after that the computer plays (not announced).
create or replace function public.battle_find(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rules  jsonb := battle_rules();
  mr     jsonb := rules->'match';
  me     public.battle_players := battle_ready(p_level);
  mine   public.battle_ratings;
  t      timestamptz := clock_timestamp();
  q      public.battle_queue;
  other  public.battle_queue;
  active uuid;
  width  int;
  waited int;
  counts boolean;
  mid    uuid;
  my_tier int;
  full_s int;
begin
  for active in select id from battle_matches where status = 'playing' and me.user_id in (p1, p2) loop
    perform battle_advance(active);
    if exists (select 1 from battle_matches where id = active and status = 'playing') then
      delete from battle_queue where user_id = me.user_id;
      return jsonb_build_object('match', active);
    end if;
  end loop;

  perform battle_check_open();
  if exists (select 1 from battle_players where user_id = me.user_id and ranked_locked) then
    raise exception '排位賽暫停中：系統偵測到疑似外掛。如果是誤判，請聯絡開發者';
  end if;
  mine := battle_rating(me.user_id);
  my_tier := battle_tier(mine.rating);

  insert into battle_queue (user_id, rating, joined_at, last_seen) values (me.user_id, mine.rating, t, t)
  on conflict (user_id) do update
    set rating = excluded.rating, last_seen = t,
        joined_at = case when battle_queue.last_seen < t - interval '5 seconds' then t else battle_queue.joined_at end
  returning * into q;

  if q.match_id is not null then
    if exists (select 1 from battle_matches where id = q.match_id and status = 'playing') then
      delete from battle_queue where user_id = me.user_id;
      return jsonb_build_object('match', q.match_id);
    end if;
    update battle_queue set match_id = null, joined_at = t where user_id = me.user_id returning * into q;
  end if;

  -- a new search needs a free match left today (Pro has no limit)
  if q.joined_at = t and coalesce(battle_free_left(me.user_id), 1) <= 0 then
    delete from battle_queue where user_id = me.user_id;
    raise exception '免費版每天 % 場排名賽，升級 Pro 就不限場次', (rules->>'free_daily')::int;
  end if;

  delete from battle_queue where last_seen < t - interval '30 seconds';

  waited := floor(extract(epoch from t - q.joined_at))::int;
  -- ±start widening by grow a second for grow_s seconds, then ±wide for wide_s seconds
  width := case when waited < (mr->>'grow_s')::int then (mr->>'start')::int + (mr->>'grow')::int * waited
                else (mr->>'wide')::int end;
  select * into other from battle_queue o
  where o.user_id <> me.user_id and o.match_id is null and o.last_seen > t - interval '4 seconds'
    and abs(o.rating - mine.rating) <= width
    and not battle_blocked_between(o.user_id, me.user_id)
  order by abs(o.rating - mine.rating), (battle_tier(o.rating) = my_tier) desc, o.joined_at
  limit 1 for update skip locked;

  if not found then
    -- after the wide search the computer comes bot_s seconds later, a different amount each search
    full_s := (mr->>'grow_s')::int + (mr->>'wide_s')::int + (mr->'bot_s'->>0)::int;
    if waited < full_s + abs(hashtext(me.user_id::text || q.joined_at::text))
                         % ((mr->'bot_s'->>1)::int - (mr->'bot_s'->>0)::int + 1) then
      return jsonb_build_object('match', null, 'waited', waited);
    end if;
    insert into battle_matches (rated, p1, bot_name, bot_rating)
    values (true, me.user_id, coalesce(battle_bot_name(me.user_id), battle_new_name()),
            greatest((rules->>'min_rating')::int, mine.rating + floor(random() * (2 * (rules->'bot'->>'rating_spread')::int + 1))::int
                     - (rules->'bot'->>'rating_spread')::int))
    returning id into mid;
    if (random() < 0.01 and not exists (select 1 from battle_blocks b where b.blocker = me.user_id and b.bot_name = battle_boss_name()))
       or exists (select 1 from battle_unlimited u where u.user_id = me.user_id and u.boss_next) then
      update battle_unlimited set boss_next = false where user_id = me.user_id;
      update battle_matches set bot_name = battle_boss_name(), bot_rating = round(bot_rating * 1.1)::int,
        boss = (array['要扛住喔', '我要把你當掉'])[1 + floor(random() * 2)::int]
      where id = mid;
    end if;
    perform battle_start(mid);
    delete from battle_queue where user_id = me.user_id;
    return jsonb_build_object('match', mid);
  end if;

  -- the same pair counts toward ratings three times a day (Taiwan time)
  select count(*) < (rules->>'pair_daily_ranked')::int into counts from battle_matches
  where rated and code is null and status <> 'waiting' and battle_local(created_at)::date = battle_local(t)::date
    and ((p1 = me.user_id and p2 = other.user_id) or (p1 = other.user_id and p2 = me.user_id));

  insert into battle_matches (rated, p1, p2, note) values (counts, other.user_id, me.user_id, case when not counts then 'pair_limit' end)
  returning id into mid;
  perform battle_start(mid);
  update battle_queue set match_id = mid where user_id = other.user_id;
  delete from battle_queue where user_id = me.user_id;
  return jsonb_build_object('match', mid);
end $$;

-- Friend match: a room with a 4-character code. Friend matches never change ratings.
create or replace function public.battle_create_room(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.battle_players := battle_ready(p_level);
  c  text;
  mid uuid;
begin
  perform battle_check_open();
  update battle_matches set status = 'finished', reason = 'abandoned', finished_at = clock_timestamp()
  where p1 = me.user_id and status = 'waiting';
  loop
    c := left(new_share_code(), 4);
    begin
      insert into battle_matches (code, rated, p1) values (c, false, me.user_id) returning id into mid;
      exit;
    exception when unique_violation then
      -- an old finished room may hold the code; free it
      update battle_matches set code = null where code = c and status = 'finished';
    end;
  end loop;
  return jsonb_build_object('match', mid, 'code', c);
end $$;

create or replace function public.battle_join(p_code text, p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.battle_players := battle_ready(p_level);
  m  public.battle_matches;
begin
  perform battle_check_open();
  select * into m from battle_matches
  where code = upper(replace(trim(p_code), '-', '')) and status = 'waiting' for update;
  if not found or m.p1_seen < clock_timestamp() - interval '15 seconds' then
    raise exception '找不到這個房間，請朋友重新建立';
  end if;
  if m.p1 = me.user_id then raise exception '這是你自己建立的房間'; end if;
  if battle_blocked_between(m.p1, me.user_id) then raise exception '無法加入'; end if;
  update battle_matches set p2 = me.user_id where id = m.id;
  perform battle_start(m.id);
  return jsonb_build_object('match', m.id);
end $$;

-- 再來一場 after a room match: the first of the two to ask opens a new room (no code), the second joins it
-- and it starts. Returns {match, waiting}.
create or replace function public.battle_rematch(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  public.battle_matches;
  n  public.battle_matches;
  other uuid;
  mid uuid;
begin
  perform battle_check_open();
  select * into m from battle_matches where id = p_match for update;
  if not found or m.rated or m.p2 is null or me not in (m.p1, m.p2) or m.status <> 'finished' then
    raise exception '這場不能再來一場';
  end if;
  other := case when me = m.p1 then m.p2 else m.p1 end;
  if battle_blocked_between(me, other) then raise exception '無法加入'; end if;
  if m.rematch is not null then
    select * into n from battle_matches where id = m.rematch for update;
    if n.status = 'waiting' and n.p1 <> me and n.p1_seen >= clock_timestamp() - interval '15 seconds' then
      update battle_matches set p2 = me where id = n.id;
      perform battle_start(n.id);
      return jsonb_build_object('match', n.id, 'waiting', false);
    end if;
    if n.status in ('waiting', 'playing') and (n.p1 = me or n.p2 = me) then
      return jsonb_build_object('match', n.id, 'waiting', n.status = 'waiting');
    end if;
  end if;
  update battle_matches set status = 'finished', reason = 'abandoned', finished_at = clock_timestamp()
  where p1 = me and status = 'waiting';
  insert into battle_matches (rated, p1) values (false, me) returning id into mid;
  update battle_matches set rematch = mid where id = m.id;
  return jsonb_build_object('match', mid, 'waiting', true);
end $$;

-- ------------------------------------------------------------------ finishing

-- Points for one player at the end of a ranked match; returns {delta, rating, breakdown}.
create or replace function public.battle_apply(p_user uuid, p_outcome text, p_opp int, p_bot boolean, p_correct int,
                                               p_ms int, p_left boolean, p_opp_left boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rules jsonb := battle_rules();
  pf    jsonb := rules->'performance';
  ro    jsonb := rules->'rookie';
  st    jsonb := rules->'streak';
  r     public.battle_ratings;
  t     jsonb;
  ts    public.battle_tier_stats;
  win   boolean := p_outcome = 'win';
  base  int;
  opp   int := 0;
  perf  int := 0;
  bonus int := 0;
  extra int := 0;
  d     int;
  before int;
  newr  int;
  streak int;
  acc   numeric := p_correct / (rules->>'rounds')::numeric;
  parts jsonb := '[]';
begin
  r := battle_rating(p_user);
  select * into r from battle_ratings where user_id = p_user and season = r.season for update;
  t := battle_tier_info(r.rating);
  before := r.rating;

  if p_outcome = 'draw' then
    update battle_ratings set games = games + 1, draws = draws + 1 where user_id = p_user and season = r.season;
    return jsonb_build_object('delta', 0, 'rating', r.rating, 'breakdown', jsonb_build_array(jsonb_build_object('label', '平手', 'value', 0)));
  end if;

  base := case when win then (t->>'win')::int else -(t->>'loss')::int end;
  if p_bot then base := base + case when win then -1 else 1 end * (rules->'bot'->>'base_penalty')::int; end if;

  if p_opp_left then
    d := round(base * (rules->'leave'->>'winner_factor')::numeric)::int;
    parts := jsonb_build_array(jsonb_build_object('label', '對手離開', 'value', d));
  else
    parts := jsonb_build_array(jsonb_build_object('label', '基本', 'value', base));
    if not p_bot then
      opp := least((rules->'opponent'->>'max')::int, greatest(-(rules->'opponent'->>'max')::int,
               trunc((p_opp - r.rating)::numeric / (rules->'opponent'->>'per')::int)::int));
      if opp <> 0 then parts := parts || jsonb_build_object('label', case when opp > 0 then '對手較強' else '對手較弱' end, 'value', opp); end if;
    end if;
    d := base + opp;
    if not p_left then
      select * into ts from battle_tier_stats where tier = (t->>'index')::int;
      perf := least((pf->>'max')::int, greatest(-(pf->>'max')::int, round(
                (p_correct - coalesce(ts.avg_correct, 7)) * (pf->>'per_correct')::numeric
                + (coalesce(ts.avg_ms, 4500) - p_ms) / 1000.0 * (pf->>'per_second')::numeric)::int));
      if perf <> 0 then parts := parts || jsonb_build_object('label', '表現', 'value', perf); end if;
      d := d + perf;
      if not win and p_correct >= (pf->>'brave_loss_correct')::int then
        parts := parts || jsonb_build_object('label', '雖敗猶榮', 'value', round(d / 2.0)::int - d);
        d := round(d / 2.0)::int;
      elsif win and p_correct <= (pf->>'weak_win_correct')::int then
        parts := parts || jsonb_build_object('label', '答對較少', 'value', round(d / 2.0)::int - d);
        d := round(d / 2.0)::int;
      end if;
    end if;
  end if;

  streak := case when win then r.win_streak + 1 else 0 end;
  if win and not p_opp_left and streak >= (st->>'from')::int then
    bonus := least((st->>'max')::int, (st->>'first')::int + (streak - (st->>'from')::int) * (st->>'step')::int);
    parts := parts || jsonb_build_object('label', format('%s 連勝', streak), 'value', bonus);
    d := d + bonus;
  end if;

  if not r.rookie_done and d > 0 then
    extra := least(round(d * ((ro->>'factor')::numeric - 1))::int, (ro->>'cap')::int - r.rookie_bonus);
    if extra > 0 then
      parts := parts || jsonb_build_object('label', '新手加成 ×1.5', 'value', extra);
      d := d + extra;
    end if;
  end if;

  if win and d < (rules->'floor'->>'win')::int then
    parts := parts || jsonb_build_object('label', '保底', 'value', (rules->'floor'->>'win')::int - d);
    d := (rules->'floor'->>'win')::int;
  elsif not win and d > -(rules->'floor'->>'loss')::int then
    parts := parts || jsonb_build_object('label', '保底', 'value', -(rules->'floor'->>'loss')::int - d);
    d := -(rules->'floor'->>'loss')::int;
  end if;

  newr := greatest((rules->>'min_rating')::int, r.rating + d);
  update battle_ratings set
    rating = newr,
    peak_rating = greatest(peak_rating, newr),
    games = games + 1,
    wins = wins + win::int,
    losses = losses + (not win)::int,
    win_streak = streak,
    rookie_games = case when rookie_done then rookie_games else rookie_games + 1 end,
    rookie_bonus = rookie_bonus + greatest(extra, 0),
    rookie_done = rookie_done or rookie_games + 1 >= (ro->>'games')::int
                  or rookie_bonus + greatest(extra, 0) >= (ro->>'cap')::int or newr >= (ro->>'until')::int,
    bot_streak = case when not p_bot then bot_streak
                      when win then greatest(bot_streak, 0) + 1 else least(bot_streak, 0) - 1 end,
    bot_recent = case when not p_bot then bot_recent
                      when (bot_streak > 0) <> win then array[acc]
                      else (bot_recent || acc)[greatest(1, coalesce(array_length(bot_recent, 1), 0) - 1):] end
  where user_id = p_user and season = r.season;
  return jsonb_build_object('delta', newr - before, 'rating', newr, 'breakdown', parts);
end $$;

-- word and tier statistics from a ranked match between two players (the computer's answers are left out)
create or replace function public.battle_learn(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  m  public.battle_matches;
  side int;
  who uuid;
  v_tier int;
  c  int;
  ms numeric;
begin
  select * into m from battle_matches where id = p_match;
  if m.p2 is null then return; end if;
  for side in 1..2 loop
    who := case when side = 1 then m.p1 else m.p2 end;
    v_tier := battle_tier((battle_rating(who)).rating);
    insert into battle_word_stats (tier, word, attempts, correct, avg_ms)
    select v_tier, r.term, 1, (pick = r.answer)::int, ms_ from (
      select r.*, case when side = 1 then r.p1_pick else r.p2_pick end as pick,
                  case when side = 1 then r.p1_ms else r.p2_ms end as ms_
      from battle_rounds r where r.match_id = p_match and r.closed_at is not null
    ) r
    on conflict (tier, word) do update set
      attempts = battle_word_stats.attempts + 1,
      correct = battle_word_stats.correct + excluded.correct,
      avg_ms = case when excluded.avg_ms is null then battle_word_stats.avg_ms
                    else round((coalesce(battle_word_stats.avg_ms, excluded.avg_ms) * battle_word_stats.attempts + excluded.avg_ms)
                               / (battle_word_stats.attempts + 1)) end;
    select count(*) filter (where pick = answer), avg(coalesce(ms_, 10000)) into c, ms from (
      select r.answer, case when side = 1 then r.p1_pick else r.p2_pick end as pick,
             case when side = 1 then r.p1_ms else r.p2_ms end as ms_
      from battle_rounds r where r.match_id = p_match and r.closed_at is not null) x;
    -- a tier's first game is blended into the defaults (7 correct, 4.5 s) like every later one,
    -- so one odd game (an auto-play test answering in 0.7 s) can't become the whole tier's normal
    insert into battle_tier_stats (tier, games, avg_correct, avg_ms) values (v_tier, 1, 7 * 0.95 + c * 0.05, 4500 * 0.95 + ms * 0.05)
    on conflict (tier) do update set games = battle_tier_stats.games + 1,
      avg_correct = battle_tier_stats.avg_correct * 0.95 + excluded.avg_correct * 0.05,
      avg_ms = battle_tier_stats.avg_ms * 0.95 + excluded.avg_ms * 0.05;
  end loop;
end $$;

create or replace function public.battle_finish(p_match uuid, p_winner uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare
  m   public.battle_matches;
  r1  public.battle_ratings;
  r2  public.battle_ratings;
  c1  int; c2 int; ms1 int; ms2 int;
  out1 text; out2 text;
  a   jsonb; b jsonb;
  quick1 int; quick2 int;
  bot1 boolean := false; bot2 boolean := false;
  void jsonb := jsonb_build_object('delta', 0, 'breakdown', jsonb_build_array(
                  jsonb_build_object('label', '疑似外掛，這場不計分', 'value', 0)));
begin
  select * into m from battle_matches where id = p_match for update;
  if m.status = 'finished' then return; end if;
  -- a match still running when the season is being settled ends without points
  if m.status = 'playing' and battle_phase() = 'settling' and m.season = battle_season() then p_reason := 'abandoned'; p_winner := null; end if;
  if m.rated and p_reason <> 'abandoned' and m.status = 'playing' then
    select count(*) filter (where p1_pick = answer), coalesce(avg(coalesce(p1_ms, 10000)), 10000),
           count(*) filter (where p2_pick = answer), coalesce(avg(coalesce(p2_ms, 10000)), 10000),
           count(*) filter (where p1_pick = answer and p1_ms < 1200),
           count(*) filter (where p2_pick = answer and p2_ms < 1200)
      into c1, ms1, c2, ms2, quick1, quick2
    from battle_rounds where match_id = p_match and closed_at is not null;
    -- 外掛偵測（battle_anticheat.sql）：10 題裡有 8 題以上在 1.2 秒內答對，人很難做到。
    -- 這場雙方都不計分，記到 battle_bot_flags（會進可疑異動並寄信），7 天內 3 次就暫停排位賽。
    bot1 := quick1 >= 8;
    bot2 := m.p2 is not null and quick2 >= 8;
    if bot1 then perform battle_flag_bot(m.p1, p_match, quick1, ms1); end if;
    if bot2 then perform battle_flag_bot(m.p2, p_match, quick2, ms2); end if;
  end if;
  if m.rated and p_reason <> 'abandoned' and m.status = 'playing' and (bot1 or bot2) then
    a := void;
    if m.p2 is not null then b := void; end if;
  elsif m.rated and p_reason <> 'abandoned' and m.status = 'playing' then
    out1 := case when p_winner is null then 'draw' when p_winner = m.p1 then 'win' else 'loss' end;
    out2 := case out1 when 'win' then 'loss' when 'loss' then 'win' else 'draw' end;
    r1 := battle_rating(m.p1);
    if m.p2 is not null then r2 := battle_rating(m.p2); end if;
    a := battle_apply(m.p1, out1, coalesce(r2.rating, m.bot_rating), m.p2 is null, c1, ms1,
                      p_reason = 'left' and out1 = 'loss', p_reason = 'left' and out1 = 'win');
    if m.p2 is not null then
      b := battle_apply(m.p2, out2, r1.rating, false, c2, ms2,
                        p_reason = 'left' and out2 = 'loss', p_reason = 'left' and out2 = 'win');
    end if;
    update battle_players set games = games + 1, wins = wins + (out1 = 'win')::int, losses = losses + (out1 = 'loss')::int,
      draws = draws + (out1 = 'draw')::int where user_id = m.p1;
    update battle_players set games = games + 1, wins = wins + (out2 = 'win')::int, losses = losses + (out2 = 'loss')::int,
      draws = draws + (out2 = 'draw')::int where user_id = m.p2;
  end if;
  update battle_matches set status = 'finished', winner = p_winner, reason = p_reason,
    p1_delta = coalesce((a->>'delta')::int, 0), p2_delta = coalesce((b->>'delta')::int, 0),
    p1_breakdown = a->'breakdown', p2_breakdown = b->'breakdown', finished_at = clock_timestamp()
  where id = p_match;
  if m.rated and p_reason = 'score' and m.p2 is not null and not (bot1 or bot2) then perform battle_learn(p_match); end if;
end $$;

-- Moves a match forward. There is no background job: every state request and answer runs this.
create or replace function public.battle_advance(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  rules jsonb := battle_rules();
  m public.battle_matches;
  r public.battle_rounds;
  t timestamptz := clock_timestamp();
  gone1 boolean;
  gone2 boolean;
  closed timestamptz;
  next_start timestamptz;
  s1 int;
  s2 int;
  c1 int;
  c2 int;
begin
  select * into m from battle_matches where id = p_match for update;
  if not found or m.status <> 'playing' then return; end if;
  if battle_phase(t) = 'settling' and m.season = battle_season(t) then
    perform battle_finish(p_match, null, 'abandoned'); return;
  end if;

  gone1 := m.p1_seen < t - interval '12 seconds';
  gone2 := m.p2 is not null and m.p2_seen < t - interval '12 seconds';
  if gone1 and gone2 then perform battle_finish(p_match, null, 'abandoned'); return; end if;
  if gone1 then perform battle_finish(p_match, coalesce(m.p2, battle_bot_id()), 'left'); return; end if;
  if gone2 then perform battle_finish(p_match, m.p1, 'left'); return; end if;

  select * into r from battle_rounds where match_id = p_match and n = m.round for update;
  if m.p2 is null and r.closed_at is null and r.p2_pick is null and t >= r.starts_at + r.bot_ms * interval '1 millisecond' then
    update battle_rounds set p2_pick = r.bot_pick, p2_ms = r.bot_ms,
      p2_points = battle_points(r.bot_ms, r.bot_pick = r.answer)
    where match_id = p_match and n = r.n
    returning * into r;
  end if;
  if r.closed_at is not null or not (t >= r.ends_at or (r.p1_pick is not null and r.p2_pick is not null)) then return; end if;

  closed := least(t, r.ends_at);
  update battle_rounds set closed_at = closed where match_id = p_match and n = m.round;
  s1 := m.p1_score + r.p1_points;
  s2 := m.p2_score + r.p2_points;
  update battle_matches set p1_score = s1, p2_score = s2 where id = p_match;

  if m.round >= (rules->>'rounds')::int then
    -- higher total wins; on equal totals, more right answers; otherwise a draw
    select count(*) filter (where p1_pick = answer), count(*) filter (where p2_pick = answer) into c1, c2
    from battle_rounds where match_id = p_match;
    perform battle_finish(p_match, case
      when s1 > s2 or (s1 = s2 and c1 > c2) then m.p1
      when s2 > s1 or (s1 = s2 and c2 > c1) then coalesce(m.p2, battle_bot_id()) end, 'score');
  else
    next_start := greatest(closed + (rules->>'reveal_ms')::int * interval '1 millisecond', t + interval '1500 milliseconds');
    update battle_rounds set starts_at = next_start, ends_at = next_start + (rules->>'round_ms')::int * interval '1 millisecond'
    where match_id = p_match and n = m.round + 1;
    -- the computer's speed follows the player's last five answers, this match's included
    if m.p2 is null and m.bot_rating is not null then
      update battle_rounds set bot_ms = round(battle_bot_ms(m.p1, battle_tier((battle_rating(m.p1)).rating))
                                              * case when m.boss is not null then 0.9 else 1 end)::int
      where match_id = p_match and n = m.round + 1;
    end if;
    update battle_matches set round = round + 1 where id = p_match;
  end if;
end $$;

-- p_ms is the time the phone measured, trusted only within one second of what the server saw.
create or replace function public.battle_answer(p_match uuid, p_round int, p_pick int, p_ms int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t  timestamptz := clock_timestamp();
  m  public.battle_matches;
  r  public.battle_rounds;
  first boolean;
  seen int;
  ms int;
  pts int;
begin
  select * into m from battle_matches where id = p_match for update;
  if not found or me not in (m.p1, coalesce(m.p2, m.p1)) then raise exception '找不到這場對戰'; end if;
  first := me = m.p1;
  select * into r from battle_rounds where match_id = p_match and n = m.round for update;
  if m.status = 'playing' and p_round = m.round and p_pick between 0 and 3 and r.closed_at is null
     and t >= r.starts_at and t < r.ends_at
     and (case when first then r.p1_pick else r.p2_pick end) is null then
    seen := (battle_ms(t) - battle_ms(r.starts_at))::int;
    ms := greatest(seen - 1000, least(seen, coalesce(p_ms, seen)), 0);
    pts := battle_points(ms, p_pick = r.answer);
    if first then
      update battle_rounds set p1_pick = p_pick, p1_ms = ms, p1_points = pts where match_id = p_match and n = r.n;
    else
      update battle_rounds set p2_pick = p_pick, p2_ms = ms, p2_points = pts where match_id = p_match and n = r.n;
    end if;
  end if;
  return battle_state(p_match);
end $$;

-- ------------------------------------------------------------------ what the apps see

create or replace function public.battle_side(p_user uuid, p_bot_name text, p_bot_rating int, p_score int, p_viewer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p public.battle_players;
  rating int;
  t jsonb;
begin
  if p_user is not null then
    select * into p from battle_players where user_id = p_user;
    rating := (battle_rating(p_user)).rating;
  else
    rating := p_bot_rating;
  end if;
  t := battle_tier_info(rating);
  -- the hidden computer shows its own tier and 9999; its real rating (10% up) still drives the match
  if p_user is null and p_bot_name = battle_boss_name() then
    return jsonb_build_object('name', p_bot_name, 'pid', battle_bot_pid(p_bot_name),
      'rating', 9999, 'tier', jsonb_array_length(battle_rules()->'tiers'), 'tier_name', '扛不住', 'score', p_score);
  end if;
  return jsonb_build_object(
    'name', coalesce(p.name, p_bot_name),
    'pid', coalesce(p.pid, battle_bot_pid(p_bot_name)),
    'rating', rating, 'tier', (t->>'index')::int, 'tier_name', t->>'name', 'score', p_score);
end $$;

create or replace function public.battle_view(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rules jsonb := battle_rules();
  me   uuid := auth.uid();
  t    timestamptz := clock_timestamp();
  m    public.battle_matches;
  r    public.battle_rounds;
  l    public.battle_rounds;
  first boolean;
  other uuid;
  mine jsonb;
  res  jsonb := jsonb_build_object('now', battle_ms(t));
  ti   jsonb;
begin
  select * into m from battle_matches where id = p_match;
  if not found or me not in (m.p1, coalesce(m.p2, m.p1)) then raise exception '找不到這場對戰'; end if;
  first := me = m.p1;
  other := case when first then m.p2 else m.p1 end;

  res := res || jsonb_build_object(
    'id', m.id, 'status', m.status, 'rated', m.rated, 'code', m.code, 'round', m.round, 'boss', m.boss,
    'rounds', (rules->>'rounds')::int, 'round_ms', (rules->>'round_ms')::int,
    'note', case when m.note = 'pair_limit' then format('你們今天已經對戰 %s 場，這場不計分', (rules->>'pair_daily_ranked')::int) end,
    'you', battle_side(me, null, null, case when first then m.p1_score else m.p2_score end, me),
    'opponent', case when other is null and m.bot_rating is null then null
                     else battle_side(other, m.bot_name, m.bot_rating, case when first then m.p2_score else m.p1_score end, me) end);

  select * into r from battle_rounds where match_id = m.id and n = m.round;
  if m.status = 'playing' then
    res := res || jsonb_build_object('starts', battle_ms(r.starts_at), 'ends', battle_ms(r.ends_at),
      'answered', (case when first then r.p1_pick else r.p2_pick end) is not null,
      'opponent_answered', (case when first then r.p2_pick else r.p1_pick end) is not null);
    if t >= r.starts_at - interval '1 second' then
      res := res || jsonb_build_object('question', jsonb_build_object(
        'n', r.n, 'to_zh', r.to_zh, 'prompt', r.prompt, 'options', to_jsonb(r.options),
        'pos', (select b.pos from battle_words b where b.term = r.term)));
    end if;
  end if;

  select * into l from battle_rounds where match_id = m.id and closed_at is not null order by n desc limit 1;
  if found then
    res := res || jsonb_build_object('last', jsonb_build_object(
      'n', l.n, 'answer', l.answer, 'term', l.term, 'zh', l.zh,
      'pick', case when first then l.p1_pick else l.p2_pick end,
      'points', case when first then l.p1_points else l.p2_points end,
      'opponent_pick', case when first then l.p2_pick else l.p1_pick end,
      'opponent_points', case when first then l.p2_points else l.p1_points end));
  end if;

  if m.status = 'finished' then
    mine := res->'you';
    ti := battle_tier_info((mine->>'rating')::int);
    res := res || jsonb_build_object('result', jsonb_build_object(
      'outcome', case when m.winner is null then 'draw' when m.winner = me then 'win' else 'loss' end,
      'reason', m.reason,
      'delta', case when first then m.p1_delta else m.p2_delta end,
      'breakdown', coalesce(case when first then m.p1_breakdown else m.p2_breakdown end, '[]'::jsonb),
      'can_rematch', not m.rated and m.p2 is not null and m.note is null,
      'rematch', (select case when x.p1 = me then 'mine' else 'theirs' end from battle_matches x
                  where x.id = m.rematch and x.status = 'waiting' and x.p1_seen >= t - interval '15 seconds'),
      'tier_from', (ti->>'from')::int, 'tier_next', (ti->>'next')::int, 'next_name', ti->>'next_name',
      'words', coalesce((select jsonb_agg(jsonb_build_object(
          'term', x.term, 'zh', x.zh,
          'right', (case when first then x.p1_pick else x.p2_pick end) is not distinct from x.answer) order by x.n)
        from battle_rounds x where x.match_id = m.id and x.closed_at is not null), '[]'::jsonb)));
  end if;
  return res;
end $$;

-- Asking a player to take the 18-question level test again (run in the SQL Editor):
--   update public.battle_players set retest = true where user_id = '<uuid>';
-- battle_me tells the app, which shows the test before the next battle and then calls battle_retest_done.
alter table public.battle_players add column if not exists retest boolean not null default false;

-- The new level replaces the old one, and this season's rating starts again from it (games and wins stay).
create or replace function public.battle_retest_done(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  lv int := least(6, greatest(1, coalesce(p_level, 3)));
  st int := battle_start_rating(lv);
begin
  if me is null then raise exception '請先登入'; end if;
  update battle_players set placed_level = lv, rating = st, retest = false where user_id = me and retest;
  if found then
    update battle_ratings set rating = st, start_rating = st, peak_rating = st
    where user_id = me and season = battle_season();
  end if;
  return battle_me(lv);
end $$;
revoke execute on function public.battle_retest_done(int) from public, anon;
grant execute on function public.battle_retest_done(int) to authenticated;

create or replace function public.battle_me(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p  public.battle_players := battle_player(p_level);
  r  public.battle_ratings;
  t  jsonb;
  s  text := battle_season();
  l  timestamp := battle_local();
  last_day date := battle_season_last(s);
  notice text;
begin
  if p.placed_level is not null then r := battle_rating(p.user_id); end if;
  t := battle_tier_info(coalesce(r.rating, battle_start_rating(p.placed_level)));
  if l::date = last_day then
    notice := case when battle_phase() <> 'open' then '賽季結算中，00:00 開放新賽季'
                   when l::time >= '23:00' then format('%s 分鐘後賽季結算，23:30 起暫停對戰到 00:00',
                                                       ceil(extract(epoch from (l::date + time '23:30') - l) / 60)::int)
                   else '今晚 23:30 賽季結算，暫停對戰到 00:00' end;
  end if;
  return jsonb_build_object('name', p.name, 'pid', p.pid,
    'rating', coalesce(r.rating, battle_start_rating(p.placed_level)), 'tier', (t->>'index')::int, 'tier_name', t->>'name',
    'tier_from', (t->>'from')::int, 'tier_next', (t->>'next')::int, 'next_name', t->>'next_name',
    'games', coalesce(r.games, 0), 'wins', coalesce(r.wins, 0), 'losses', coalesce(r.losses, 0), 'draws', coalesce(r.draws, 0),
    'streak', coalesce(r.win_streak, 0),
    'season', battle_season_label(s), 'season_notice', notice, 'open', battle_phase() = 'open',
    'free_left', battle_free_left(p.user_id), 'hidden', p.hide_board, 'name_locked', p.name_locked, 'retest', p.retest,
    'badges', coalesce((select jsonb_agg(jsonb_build_object('season', battle_season_label(b.season), 'name', b.name) order by b.season desc)
                        from battle_badges b where b.user_id = p.user_id), '[]'::jsonb));
end $$;

create or replace function public.battle_set_name(p_name text, p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.battle_players := battle_player(p_level);
  clean text := btrim(regexp_replace(coalesce(p_name, ''), '[[:space:]　]+', ' ', 'g'));
begin
  if me.name_locked then raise exception '你的名稱被檢舉，審核完成前不能修改'; end if;
  if char_length(clean) not between 2 and 12 then raise exception '名稱要 2 到 12 個字'; end if;
  if clean ~ '[[:cntrl:]]' or clean ~ U&'[\200B-\200F\202A-\202E\2060-\2069\FEFF]' then
    raise exception '名稱有不能使用的字元';
  end if;
  if battle_name_problem(clean) is not null then raise exception '%', battle_name_problem(clean); end if;
  if exists (select 1 from unnest(battle_bot_names() || battle_boss_name()) n where lower(n) = lower(clean)) then raise exception '這個名稱已經有人使用'; end if;
  perform pg_advisory_xact_lock(hashtext('battle_set_name'));
  if exists (select 1 from battle_players where lower(name) = lower(clean) and user_id <> me.user_id) then
    raise exception '這個名稱已經有人使用';
  end if;
  update battle_players set name = clean where user_id = me.user_id;
  return battle_me(p_level);
end $$;

create or replace function public.battle_set_hidden(p_hidden boolean) returns void
language sql security definer set search_path = public as $$
  update battle_players set hide_board = p_hidden where user_id = auth.uid()
$$;

-- ------------------------------------------------------------------ leaderboard

-- what the caller sees for someone on the board: hidden players and players the caller blocked are 匿名玩家
create or replace function public.battle_board_name(p_user uuid, p_viewer uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when p_user = p_viewer then p.name
              when p.hide_board or exists (select 1 from battle_blocks b where b.blocker = p_viewer and b.blocked = p_user) then '匿名玩家'
              else p.name end
  from battle_players p where p.user_id = p_user
$$;

-- One season's top 20 among players with at least p_min ranked games, and the viewer's own row
-- (rank null when they haven't played enough).
create or replace function public.battle_board_season(p_season text, p_min int, p_viewer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  top  jsonb;
  mine jsonb;
begin
  with ranked as (
    select r.*, row_number() over (order by r.rating desc, r.peak_rating desc, r.user_id) as place
    from battle_ratings r where r.season = p_season and r.games >= p_min
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', place, 'name', battle_board_name(user_id, p_viewer),
           'pid', case when battle_board_name(user_id, p_viewer) = '匿名玩家' then null
                       else (select pid from battle_players where user_id = ranked.user_id) end,
           'rating', rating, 'tier_name', battle_tier_info(rating)->>'name',
           'win_rate', round(wins::numeric / greatest(games, 1), 3), 'me', user_id = p_viewer) order by place)
           filter (where place <= (battle_rules()->'leaderboard'->>'top')::int), '[]'::jsonb),
         (select jsonb_build_object('rank', place, 'rating', rating, 'tier_name', battle_tier_info(rating)->>'name',
                                    'win_rate', round(wins::numeric / greatest(games, 1), 3), 'games', games)
            from ranked where user_id = p_viewer)
    into top, mine
  from ranked;
  if mine is null then
    select jsonb_build_object('rank', null, 'rating', rating, 'tier_name', battle_tier_info(rating)->>'name',
                              'win_rate', round(wins::numeric / greatest(games, 1), 3), 'games', games)
      into mine from battle_ratings where user_id = p_viewer and season = p_season and games > 0;
  end if;
  return jsonb_build_object('top', top, 'me', mine);
end $$;

-- This season live (10 games to be listed) and last season's final board (60 games).
create or replace function public.battle_board() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  lb   jsonb := battle_rules()->'leaderboard';
  me   uuid := auth.uid();
  s    text := battle_season();
  prev text := battle_season_prev(s);
begin
  if me is null then raise exception '請先登入'; end if;
  return jsonb_build_object('season', battle_season_label(s), 'previous', battle_season_label(prev),
    'has_previous', exists (select 1 from battle_ratings where season = prev and games > 0),
    'min_games', (lb->>'min_games')::int, 'live_min_games', (lb->>'live_min_games')::int,
    'current', battle_board_season(s, (lb->>'live_min_games')::int, me),
    'last', battle_board_season(prev, (lb->>'min_games')::int, me));
end $$;

-- 00:05 every day: how this season's ratings are spread, for next season's estimates
create or replace function public.battle_snapshot() returns void
language sql security definer set search_path = public as $$
  insert into battle_snapshots (season, day, histogram)
  select battle_season(), battle_local()::date - battle_season_first(battle_season()) + 1,
         coalesce(jsonb_object_agg(b, n), '{}'::jsonb)
  from (select (rating / 10) * 10 as b, count(*) as n from battle_ratings
        where season = battle_season() and games > 0 group by 1) x
  on conflict (season, day) do update set histogram = excluded.histogram
$$;

-- 23:59 on a season's last day: badges for the season's highest tier and next season's starting ratings.
-- Safe to run again; ratings for anyone it misses are made the same way on their next match.
create or replace function public.battle_season_reset(p_season text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  s    text := coalesce(p_season, battle_season());
  nxt  text := battle_season((battle_season_last(s) + 1)::timestamp at time zone 'Asia/Taipei' + interval '12 hours');
begin
  insert into battle_badges (user_id, season, tier, name)
  select user_id, s, (battle_tier_info(peak_rating)->>'index')::int, battle_tier_info(peak_rating)->>'name'
  from battle_ratings where season = s and games > 0
  on conflict do nothing;
  insert into battle_ratings (user_id, season, rating, start_rating, peak_rating, rookie_done)
  select user_id, nxt, x, x, x, true from (
    select user_id, (battle_rules()->'start_rating'->>(least(6, battle_tier(rating)) - 1))::int as x
    from battle_ratings where season = s and games > 0) r
  on conflict do nothing;
end $$;

create or replace function public.battle_season_cron() returns void
language plpgsql security definer set search_path = public as $$
begin
  if battle_local()::date = battle_season_last(battle_season()) then perform battle_season_reset(); end if;
end $$;

-- ------------------------------------------------------------------ reports and blocks

-- p_pid is the id the apps got with an opponent or a leaderboard row.
create or replace function public.battle_find_pid(p_pid text, out who uuid, out bot text, out name text) returns record
language plpgsql stable security definer set search_path = public as $$
begin
  select p.user_id, null, p.name into who, bot, name from battle_players p where p.pid = p_pid;
  if who is null then
    select n, n into bot, name from unnest(battle_bot_names() || battle_boss_name()) n where battle_bot_pid(n) = p_pid;
  end if;
  if who is null and bot is null then raise exception '找不到這位玩家'; end if;
end $$;

-- Three different players reporting the same name hides it as 玩家 + 4 digits until someone checks it;
-- a reported computer name is taken out of use.
create or replace function public.battle_report(p_pid text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f  record;
  n  int;
begin
  if me is null then raise exception '請先登入'; end if;
  if p_reason not in ('vulgar', 'offensive', 'impersonation', 'other') then raise exception '請選擇原因'; end if;
  select * into f from battle_find_pid(p_pid);
  if f.who = me then raise exception '不能檢舉自己'; end if;
  insert into nickname_reports (reporter, target, nickname, reason) values (me, f.who, f.name, p_reason)
  on conflict (reporter, nickname) do nothing;
  if f.bot is not null then
    insert into battle_bot_removed (name) values (f.bot) on conflict do nothing;
    return;
  end if;
  select count(distinct reporter) into n from nickname_reports where target = f.who and nickname = f.name and status = 'pending';
  if n >= 3 then
    insert into battle_locked_names (name) values (f.name) on conflict do nothing;
    update battle_players set name = '玩家' || lpad(floor(random() * 10000)::int::text, 4, '0'), name_locked = true
    where user_id = f.who;
    update nickname_reports set status = 'locked' where target = f.who and nickname = f.name;
  end if;
end $$;

create or replace function public.battle_block(p_pid text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f  record;
begin
  if me is null then raise exception '請先登入'; end if;
  select * into f from battle_find_pid(p_pid);
  if f.who = me then raise exception '不能封鎖自己'; end if;
  if (select count(*) from battle_blocks where blocker = me) >= 200 then raise exception '最多封鎖 200 人'; end if;
  insert into battle_blocks (blocker, blocked, bot_name, name) values (me, f.who, f.bot, f.name) on conflict do nothing;
end $$;

create or replace function public.battle_blocked() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by created_at desc), '[]'::jsonb)
  from battle_blocks where blocker = auth.uid()
$$;

create or replace function public.battle_unblock(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from battle_blocks where id = p_id and blocker = auth.uid()
$$;

-- ------------------------------------------------------------------ jobs

create extension if not exists pg_cron;
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname in ('battle-season-reset', 'battle-snapshot');
end $$;
-- 23:59 Taiwan time (UTC+8)
select cron.schedule('battle-season-reset', '59 15 * * *', 'select public.battle_season_cron()');

-- ------------------------------------------------------------------ access

revoke all on public.battle_players, public.battle_words, public.battle_matches, public.battle_rounds,
  public.battle_queue, public.battle_rules, public.battle_ratings, public.battle_badges, public.battle_word_stats,
  public.battle_tier_stats, public.battle_snapshots, public.battle_blocks, public.nickname_reports,
  public.battle_locked_names, public.battle_bot_removed, public.battle_banned_words, public.battle_unlimited
  from public, anon, authenticated;
grant select on public.entitlements to authenticated;

do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'battle\_%' or p.proname = 'has_pro') loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

grant execute on function public.battle_me(int), public.battle_set_name(text, int), public.battle_find(int), public.battle_cancel_find(),
  public.battle_create_room(int), public.battle_join(text, int), public.battle_rematch(uuid), public.battle_state(uuid),
  public.battle_answer(uuid, int, int, int), public.battle_quit(uuid), public.battle_board(), public.battle_report(text, text),
  public.battle_block(text), public.battle_blocked(), public.battle_unblock(bigint), public.battle_set_hidden(boolean),
  public.battle_dev_limit(boolean)
  to authenticated;

-- 上面的迴圈也會收回 battle_social.sql／battle_lobby.sql 的函式（好友列表、房間等候室、邀請…），
-- 重跑這個檔時把它們還回去（和 battle_grants.sql 同一份清單；還沒建立的函式自動跳過）
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             'battle_retest_done',
             'battle_room_add_bot', 'battle_room_set_public', 'battle_public_rooms', 'battle_join_public',
             'battle_add_friend', 'battle_remove_friend', 'battle_friend_list', 'battle_tier_detail',
             'battle_room_state', 'battle_room_ready', 'battle_room_start', 'battle_room_kick',
             'battle_room_invite', 'battle_my_invites', 'battle_invite_dismiss', 'battle_room_invited'])
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

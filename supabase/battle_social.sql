-- 房間加電腦、公開／私人房間、好友、電腦玩家排行、段位詳細、電腦每天全天互打。在 battle_ranked.sql 之後執行（可以重複執行）。

-- ------------------------------------------------------------------ 房間
alter table public.battle_matches add column if not exists is_public boolean not null default false;
create index if not exists battle_matches_public on public.battle_matches (created_at desc)
  where is_public and status = 'waiting';

-- 房主在房間裡等不到人：補一台電腦進來，馬上開始。房間對戰一律不計分。
create or replace function public.battle_room_add_bot(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  rules  jsonb := battle_rules();
  me     uuid := auth.uid();
  m      public.battle_matches;
  r      int;
  spread int := coalesce((rules->'bot'->>'rating_spread')::int, 0);
begin
  perform battle_check_open();
  select * into m from battle_matches where id = p_match for update;
  if not found or m.p1 <> me or m.code is null then raise exception '找不到這個房間'; end if;
  if m.status <> 'waiting' or m.p2 is not null then raise exception '房間已經開始了'; end if;
  r := (battle_rating(me)).rating;
  update battle_matches set
    bot_name = coalesce(battle_bot_name(me), battle_new_name()),
    bot_rating = greatest((rules->>'min_rating')::int, r + floor(random() * (2 * spread + 1))::int - spread),
    is_public = false
  where id = m.id;
  perform battle_start(m.id);
  return jsonb_build_object('match', m.id);
end $$;

-- 公開房間會出現在「公開房間」列表，任何人都能直接加入；私人房間只能用代碼、連結或 QR code
create or replace function public.battle_room_set_public(p_match uuid, p_public boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update battle_matches set is_public = coalesce(p_public, false)
  where id = p_match and p1 = auth.uid() and status = 'waiting' and code is not null and p2 is null;
  if not found then raise exception '找不到這個房間'; end if;
  return jsonb_build_object('public', coalesce(p_public, false));
end $$;

create or replace function public.battle_public_rooms() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
    select battle_side(m.p1, null, null, 0, auth.uid())
           || jsonb_build_object('code', m.code, 'at', m.created_at) as x
    from battle_matches m
    where m.is_public and m.status = 'waiting' and m.code is not null and m.p2 is null
      and m.p1_seen >= clock_timestamp() - interval '15 seconds'
      and m.p1 <> auth.uid() and not battle_blocked_between(m.p1, auth.uid())
    order by m.created_at desc
    limit 30
  ) s
$$;

-- 從「公開房間」列表加入：房間現在還要是公開的。列表最多 5 秒才更新一次，房主改成私人後
-- 別人畫面上可能還看得到；用這個函式加入就會被擋下。用代碼、連結或 QR code 加入仍走 battle_join。
-- 先鎖住這一列再檢查，房主同時切換公開／私人時以先拿到鎖的為準。
create or replace function public.battle_join_public(p_code text, p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pub boolean;
begin
  select is_public into pub from battle_matches
  where code = upper(replace(trim(p_code), '-', '')) and status = 'waiting' for update;
  if not found then raise exception '找不到這個房間，請朋友重新建立'; end if;
  if not pub then raise exception '這個房間已經改成私人房間了'; end if;
  return battle_join(p_code, p_level);
end $$;

-- ------------------------------------------------------------------ 好友
-- 好友代碼就是 battle_players.pid（10 碼，本來就公開、唯一），App 顯示成大寫。加好友是雙向的。
create table if not exists public.battle_friends (
  user_id    uuid not null references auth.users on delete cascade,
  friend_id  uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
alter table public.battle_friends enable row level security;
revoke all on public.battle_friends from public, anon, authenticated;

create or replace function public.battle_add_friend(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  who uuid;
begin
  if me is null then raise exception '請先登入'; end if;
  select user_id into who from battle_players
  where pid = lower(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
  if who is null then raise exception '找不到這個好友代碼'; end if;
  if who = me then raise exception '這是你自己的好友代碼'; end if;
  if battle_blocked_between(me, who) then raise exception '無法加好友'; end if;
  if (select count(*) from battle_friends where user_id = me) >= 200 then raise exception '好友最多 200 位'; end if;
  insert into battle_friends (user_id, friend_id) values (me, who), (who, me) on conflict do nothing;
  return battle_side(who, null, null, 0, me);
end $$;

create or replace function public.battle_remove_friend(p_pid text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  who uuid;
begin
  select user_id into who from battle_players where pid = lower(trim(coalesce(p_pid, '')));
  if who is null then return; end if;
  delete from battle_friends where (user_id = me and friend_id = who) or (user_id = who and friend_id = me);
end $$;

-- 好友列表；room 是好友現在開著、還在等人的房間代碼（可以一鍵加入），沒有就是 null
create or replace function public.battle_friend_list() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by (x->>'room') is null, x->>'name'), '[]'::jsonb) from (
    select battle_side(f.friend_id, null, null, 0, auth.uid()) || jsonb_build_object('room', (
      select m.code from battle_matches m
      where m.p1 = f.friend_id and m.status = 'waiting' and m.code is not null and m.p2 is null
        and m.p1_seen >= clock_timestamp() - interval '15 seconds'
      order by m.created_at desc limit 1)) as x
    from battle_friends f
    where f.user_id = auth.uid() and not battle_blocked_between(f.user_id, f.friend_id)
  ) s
$$;

-- ------------------------------------------------------------------ 電腦玩家（排行和分數分布）
-- 每個賽季一開始，battle_bot_names() 裡的電腦平均分到 battle_rules 的起始分數（900、1000…1400），
-- 之後跟真人打排位賽才會加減分，像真人一樣自由爬分、掉分。電腦也算進分數分布、贏過幾 % 和賽季排行。
-- 排位賽配到電腦時，挑積分最接近這位玩家的電腦（最接近的 5 台裡隨機一台）。
-- 玩家這邊的加減分不受電腦積分影響（battle_apply 對電腦局本來就不算對手強弱）。
create table if not exists public.battle_bot_ratings (
  season      text not null,
  name        text not null,
  rating      int not null,
  peak_rating int not null,
  games       int not null default 0,
  wins        int not null default 0,
  losses      int not null default 0,
  draws       int not null default 0,
  primary key (season, name)
);
alter table public.battle_bot_ratings enable row level security;
revoke all on public.battle_bot_ratings from public, anon, authenticated;
alter table public.battle_bot_ratings add column if not exists strength int;  -- 隱藏實力，只用在電腦互打
alter table public.battle_bot_ratings add column if not exists sim_games int not null default 0;   -- 電腦互打場數
alter table public.battle_bot_ratings add column if not exists real_games int not null default 0;  -- 跟真人打的排位賽場數

-- 這個賽季還沒排好電腦就排一次（名單新加的電腦也會補上）；可以重複呼叫
create or replace function public.battle_bot_seed(p_season text) returns void
language plpgsql security definer set search_path = public as $$
declare
  starts jsonb := battle_rules()->'start_rating';
  k      int := jsonb_array_length(starts);
begin
  -- 隱藏實力：只用在電腦互打（battle_bot_sim）算勝負。照起始分數分配：同一個起始分數的電腦平均分到
  -- 起始分數 −50～+49（例如 900 分那組是 850～949），六組接起來是 850～1449 的均勻分布，不會有電腦實力遠超過自己那組。
  update battle_bot_ratings set strength = rating - 50 + floor(random() * 100)::int
  where season = p_season and strength is null;
  if (select count(*) from battle_bot_ratings where season = p_season) >= cardinality(battle_bot_names()) then return; end if;
  insert into battle_bot_ratings (season, name, rating, peak_rating, strength)
  select p_season, n, v, v, v - 50 + floor(100 * (j - 0.5) / m)::int from (
    select n, v, row_number() over (partition by v order by md5(n)) as j, count(*) over (partition by v) as m from (
    select n, (starts->>(((row_number() over (order by md5(n))) - 1) % k)::int)::int as v
    from unnest(battle_bot_names()) n) x) y
  on conflict do nothing;
end $$;

-- 不上排行榜的「浮動電腦」：不在 battle_bot_names() 名單裡，所以不排分數、不互打、不上排行、不算進分布。
-- 配對時名單上最接近的電腦跟玩家差超過 100 分（例如特高端或特低端玩家），就改配一台浮動電腦，
-- 它的積分是這位玩家的積分隨機 ±30（battle_ranked.sql 建立電腦局時本來就這樣給，名單上的電腦才會被觸發器換掉），
-- 答對率和答題時間也跟著這個積分，所以特高端玩家不會一直被配到低很多的電腦、被往下拉。
create or replace function public.battle_float_names() returns text[]
language sql immutable set search_path = public as $$
  select array['路過的卷王','夜貓子讀書中','背單字的貓','早起的鳥兒','noah_0417','mia.tw','好想睡覺喔','咖啡因成癮',
               'hank_0730','單字吃到飽','zoe_lin','考前抱佛腳']
$$;

-- 排位賽要配電腦時用的名字：差距 100 分以內、積分最接近這位玩家的 5 台電腦裡隨機一台；一台都沒有就改配浮動電腦。
-- （DC-42B9E8D9 修正：以前只檢查最接近那台差不差超過 100，隨機挑到第 2～5 台時可能差 100 分以上）
-- 房間的電腦（不計分）也用這個名字
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
revoke all on function public.battle_float_names() from public, anon, authenticated;


-- 排位賽一建立，電腦的顯示積分就用名單上它目前的積分
create or replace function public.battle_bot_match_rating() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v int;
begin
  if new.rated and new.p2 is null and new.code is null and new.bot_name is not null then
    select rating into v from battle_bot_ratings where season = coalesce(new.season, battle_season()) and name = new.bot_name;
    if found then new.bot_rating := v; end if;
  end if;
  return new;
end $$;

-- 排位賽打完：電腦照雙方積分差加減分（Elo，K = 16，和電腦互打同一套），玩家贏就扣、玩家輸就加、平手看差距。
-- 不再用段位的固定分數：以前電腦打贏一直掉分的同學就固定 +18～+28，會一路衝到比隱藏實力高很多。積分最低 min_rating
create or replace function public.battle_bot_match_done() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  b    public.battle_bot_ratings;
  hr   int;
  e    numeric;
  outc text;
  newr int;
begin
  if not (old.status = 'playing' and new.status = 'finished' and new.rated and new.p2 is null and new.code is null
          and new.bot_name is not null and coalesce(new.reason, '') <> 'abandoned') then
    return null;
  end if;
  select * into b from battle_bot_ratings
  where season = coalesce(new.season, battle_season()) and name = new.bot_name for update;
  if not found then return null; end if;
  outc := case when new.winner is null then 'draw' when new.winner = new.p1 then 'loss' else 'win' end;
  hr := coalesce((select rating from battle_ratings where user_id = new.p1 and season = b.season), b.rating);
  e := 1 / (1 + power(10::numeric, (hr - b.rating) / 400.0));
  newr := greatest((battle_rules()->>'min_rating')::int,
          b.rating + round(16 * (case outc when 'win' then 1 when 'loss' then 0 else 0.5 end - e))::int);
  update battle_bot_ratings set rating = newr, peak_rating = greatest(peak_rating, newr), games = games + 1, real_games = real_games + 1,
    wins = wins + (outc = 'win')::int, losses = losses + (outc = 'loss')::int, draws = draws + (outc = 'draw')::int
  where season = b.season and name = b.name;
  return null;
end $$;

drop trigger if exists battle_bot_match_rating on public.battle_matches;
create trigger battle_bot_match_rating before insert on public.battle_matches
  for each row execute function public.battle_bot_match_rating();
drop trigger if exists battle_bot_match_done on public.battle_matches;
create trigger battle_bot_match_done after update of status on public.battle_matches
  for each row execute function public.battle_bot_match_done();

-- 一個賽季的所有積分：打過排位賽的真人＋這季的電腦（還在名單上、沒被移除的）
create or replace function public.battle_season_pool(p_season text, p_min int default 0)
returns table (user_id uuid, bot text, rating int, peak_rating int, games int, wins int)
language sql stable security definer set search_path = public as $$
  select r.user_id, null::text, r.rating, r.peak_rating, r.games, r.wins
  from battle_ratings r where r.season = p_season and r.games > 0 and r.games >= p_min
  union all
  select null::uuid, b.name, b.rating, b.peak_rating, b.games, b.wins
  from battle_bot_ratings b
  where b.season = p_season and b.name = any(battle_bot_names())
    -- 電腦上榜：互打滿 20 場或跟真人打滿 10 場（p_min 是 0 時是算分布，全部都算）
    and (p_min = 0 or b.sim_games >= 20 or b.real_games >= 10)
    and not exists (select 1 from battle_bot_removed x where x.name = b.name)
$$;

-- 賽季排行（取代 battle_ranked.sql 的版本）：電腦也一起排名，打滿場數一樣會上榜。
-- 電腦的 pid 用 battle_bot_pid，排行上長按電腦一樣可以檢舉或封鎖。
create or replace function public.battle_board_season(p_season text, p_min int, p_viewer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  top  jsonb;
  mine jsonb;
begin
  with ranked as (
    select p.*, row_number() over (order by p.rating desc, p.peak_rating desc, coalesce(p.user_id::text, p.bot)) as place
    from battle_season_pool(p_season, p_min) p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', place, 'name', coalesce(bot, battle_board_name(user_id, p_viewer)),
           'pid', case when bot is not null then battle_bot_pid(bot)
                       when battle_board_name(user_id, p_viewer) = '匿名玩家' then null
                       else (select pid from battle_players where user_id = ranked.user_id) end,
           'rating', rating, 'tier_name', battle_tier_info(rating)->>'name',
           'win_rate', round(wins::numeric / greatest(games, 1), 3), 'me', coalesce(user_id = p_viewer, false)) order by place)
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

-- 賽季排行（取代 battle_ranked.sql 的版本）：2026 S6 是第一季，開發時測試留下的更早賽季不算，
-- 所以第一季不顯示「上賽季最終排名」；第二季起才顯示。
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
    'has_previous', prev >= '2026-S6' and (
      exists (select 1 from battle_ratings where season = prev and games > 0)
      or exists (select 1 from battle_bot_ratings where season = prev)),
    'min_games', (lb->>'min_games')::int, 'live_min_games', (lb->>'live_min_games')::int,
    'current', battle_board_season(s, (lb->>'live_min_games')::int, me),
    'last', battle_board_season(prev, (lb->>'min_games')::int, me));
end $$;

-- ------------------------------------------------------------------ 段位詳細
-- 這個賽季的真人＋電腦：每 50 分有幾個人（含電腦）、各段位的勝率（只看真人，見下面）和重置分數，以及自己的勝率、贏過多少比例的玩家。
-- 只回統計數字，不回任何人的名字。段位用 battle_rules 的 tiers（from 小於等於積分的最後一個）。
create or replace function public.battle_tier_detail() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me     uuid := auth.uid();
  s      text := battle_season();
  tiers  jsonb := battle_rules()->'tiers';
  mine   public.battle_ratings;
  total  int;
  below  int;
  t_out  jsonb;
  hist   jsonb;
begin
  if me is null then raise exception '請先登入'; end if;
  perform battle_bot_seed(s);
  select count(*) into total from battle_season_pool(s);
  select * into mine from battle_ratings where user_id = me and season = s and games > 0;
  if mine.user_id is not null then
    select count(*) into below from battle_season_pool(s) p where p.rating < mine.rating;
  end if;

  -- 勝率只看真人（電腦互打是另一套加減分，勝率會全擠在五成附近，不能代表真人）。
  -- 理論值＝長期不加不減分時的勝率：贏一場 +win、輸一場 −loss，所以是 loss ÷ (win + loss)。
  -- 顯示值＝(真人贏的場數 + 理論值 × 30) ÷ (真人勝敗場數 + 30)：真人打得少時接近理論值，打得越多越接近真人實際勝率。
  -- 平手不算。這個段位真人勝敗不到 50 場時標成估計值（畫面上加「約」）。
  with r as (
    select p.rating, p.games, p.user_id is not null as real,
           (select count(*) from jsonb_array_elements(tiers) e where p.rating >= (e->>'from')::int) as t
    from battle_season_pool(s) p
  ), h as (
    select x.wins, x.losses, (select count(*) from jsonb_array_elements(tiers) e where x.rating >= (e->>'from')::int) as t
    from battle_ratings x where x.season = s and x.games > 0
  ), c as (
    select k, round((tiers->k->>'loss')::numeric / ((tiers->k->>'win')::int + (tiers->k->>'loss')::int), 3) as theory,
           coalesce((select sum(h.wins) from h where h.t = k + 1), 0) as hw,
           coalesce((select sum(h.wins + h.losses) from h where h.t = k + 1), 0) as hg
    from generate_series(0, jsonb_array_length(tiers) - 1) k
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'index', k + 1, 'name', tiers->k->>'name', 'from', (tiers->k->>'from')::int,
           'next', (tiers->(k + 1)->>'from')::int,
           'win', (tiers->k->>'win')::int, 'loss', (tiers->k->>'loss')::int,
           -- 賽季結束時停在這個段位，下賽季從幾分開始（和 battle_season_reset 同一條規則）
           'reset', (battle_rules()->'start_rating'->>(least(6, k + 1) - 1))::int,
           -- 人數含電腦，用來算分布
           'players', (select count(*) from r where r.t = k + 1),
           'estimated', hg < 50,
           'win_rate', round((hw + theory * 30) / (hg + 30), 3))
         order by k), '[]'::jsonb)
    into t_out
  from c;
  select coalesce(jsonb_agg(jsonb_build_object('from', b, 'n', n) order by b), '[]'::jsonb) into hist
  from (select (p.rating / 50) * 50 as b, count(*) as n from battle_season_pool(s) p group by 1) x;

  return jsonb_build_object('season', battle_season_label(s), 'season_end', battle_season_last(s),
    'players', total, 'tiers', t_out, 'histogram', hist,
    'me', case when mine.user_id is null then null else jsonb_build_object(
      'rating', mine.rating, 'games', mine.games, 'wins', mine.wins, 'losses', mine.losses, 'draws', mine.draws,
      'win_rate', round(mine.wins::numeric / greatest(mine.games, 1), 3),
      'percentile', case when total > 1 then round(below::numeric / (total - 1), 3) end) end);
end $$;

-- ------------------------------------------------------------------ 權限
revoke all on function public.battle_room_add_bot(uuid), public.battle_room_set_public(uuid, boolean),
  public.battle_public_rooms(), public.battle_join_public(text, int), public.battle_add_friend(text), public.battle_remove_friend(text),
  public.battle_friend_list(), public.battle_tier_detail() from public, anon;
grant execute on function public.battle_room_add_bot(uuid), public.battle_room_set_public(uuid, boolean),
  public.battle_public_rooms(), public.battle_join_public(text, int), public.battle_add_friend(text), public.battle_remove_friend(text),
  public.battle_friend_list(), public.battle_tier_detail() to authenticated;
-- 內部用：只給其他函式和觸發器呼叫，App 不能直接呼叫（新建的函式預設所有人都能執行）
revoke all on function public.battle_bot_seed(text), public.battle_season_pool(text, int), public.battle_bot_name(uuid),
  public.battle_bot_match_rating(), public.battle_bot_match_done() from public, anon, authenticated;

-- ------------------------------------------------------------------ 電腦互打
-- 電腦每天全天（台北 00:00–23:59:59）自己互打，預設一天 14400 場（平均每分鐘 10 場），讓電腦的積分散開，
-- （DC-42B9E8D9：原本是離峰 02:00–06:00 打 2500 場）
-- 分布才不會全擠在 900/1000/…/1400 六個起始分數上。
-- 互打不建立對戰紀錄（battle_matches、題目、作答都不寫），只更新 battle_bot_ratings，所以不會留下垃圾資料；
-- battle_bot_sim_days 每天只留一列「今天打了幾場」，超過 30 天的自動刪掉。
-- 勝負：照兩台的「隱藏實力」差用 Elo 期望值抽籤（差 400 時強的贏 10/11），5% 平手。
-- 加減分看雙方積分差（Elo，K = 16，一場最多 ±16）：贏比自己低分的加得少、輸給比自己高分的扣得少，一方加多少另一方就扣多少，
-- 所以整體分數不會往上漂，每台電腦的積分會慢慢停在接近它的隱藏實力。電腦跟真人打完也用同一套（battle_bot_match_done）。
-- 電腦自己的勝率因此會在五成附近；段位詳細的勝率只看真人（battle_tier_detail），不受互打影響。
-- 隱藏實力只用在這裡。電腦跟真人打時，強度照真人平均和電腦積分算（battle_bot_target、battle_bot_ms）。
create table if not exists public.battle_bot_sim_days (
  day     date primary key,               -- 台北日期
  target  int not null default 14400,     -- 這天要打幾場
  from_t  time not null default '00:00',  -- 從這個時間開始打（台北時間）
  until_t time not null default '23:59:59',  -- 在這個時間前打完（台北時間）
  played  int not null default 0
);
alter table public.battle_bot_sim_days add column if not exists from_t time not null default '00:00';
alter table public.battle_bot_sim_days add column if not exists asap boolean not null default false;  -- true：不管時段，每分鐘打 1000 場直到打完
alter table public.battle_bot_sim_days alter column target set default 14400;
alter table public.battle_bot_sim_days alter column from_t set default '00:00';
alter table public.battle_bot_sim_days alter column until_t set default '23:59:59';
alter table public.battle_bot_sim_days enable row level security;
revoke all on public.battle_bot_sim_days from public, anon, authenticated;

-- 今天起已經建立的列（不是 asap 的）也改成全天 14400 場；剩下的場數會平均分到今天剩下的分鐘
update public.battle_bot_sim_days set target = 14400, from_t = '00:00', until_t = '23:59:59'
where day >= public.battle_local()::date and not asap;

-- 2026-11-22：執行這份 SQL 後 1 分鐘內開始，盡快打完 20000 場（排程每分鐘一次、每次 1000 場，約 20 分鐘）（已過去的日子，留著不影響）
insert into public.battle_bot_sim_days (day, target, from_t, until_t, asap) values ('2026-11-22', 20000, '00:00', '23:59', true)
on conflict (day) do update set target = excluded.target, from_t = excluded.from_t, until_t = excluded.until_t, asap = excluded.asap;

-- 隱藏實力改成照起始分數分配、K 改 16 後重來一次（每個 tag 只做一次，重複執行這份 SQL 不會再重置；sim-elo-2026-11-22 是上一次）：
-- 刪掉這個賽季的電腦積分（之後自動照起始分數重新排好、重新分配隱藏實力），今天的 20000 場從 0 重新打
create table if not exists public.battle_bot_resets (tag text primary key, at timestamptz not null default now());
alter table public.battle_bot_resets enable row level security;
revoke all on public.battle_bot_resets from public, anon, authenticated;
do $$ begin
  insert into public.battle_bot_resets (tag) values ('start-strength-2026-11-22') on conflict do nothing;
  if found then
    delete from public.battle_bot_ratings where season = public.battle_season();
    update public.battle_bot_sim_days set played = 0 where day = '2026-11-22';
  end if;
end $$;

-- 打 n 場電腦互打，回傳實際打了幾場
create or replace function public.battle_bot_sim(p_n int) returns int
language plpgsql security definer set search_path = public as $$
declare
  s    text := battle_season();
  minr int := (battle_rules()->>'min_rating')::int;
  a    public.battle_bot_ratings;
  b    public.battle_bot_ratings;
  ea   numeric;   -- 照積分差算的 a 期望得分（Elo）
  d    int;       -- a 這場加幾分（b 扣同樣的分數）
  pa   numeric;
  roll numeric;
  outa text;
  done int := 0;
begin
  if battle_phase() <> 'open' then return 0; end if;   -- 賽季結算那段時間不打
  perform battle_bot_seed(s);
  for i in 1 .. greatest(coalesce(p_n, 0), 0) loop
    select * into a from battle_bot_ratings x
    where x.season = s and x.name = any(battle_bot_names())
      and not exists (select 1 from battle_bot_removed r where r.name = x.name)
    order by random() limit 1;
    exit when not found;
    -- 對手：積分最接近的 6 台裡隨機一台，和排位賽配對一樣挑分數相近的
    select * into b from (
      select * from battle_bot_ratings x
      where x.season = s and x.name <> a.name and x.name = any(battle_bot_names())
        and not exists (select 1 from battle_bot_removed r where r.name = x.name)
      order by abs(x.rating - a.rating), random() limit 6) y
    order by random() limit 1;
    exit when not found;
    pa := 1 / (1 + power(10::numeric, (coalesce(b.strength, b.rating) - coalesce(a.strength, a.rating)) / 400.0));
    roll := random();
    outa := case when roll < 0.05 then 'draw' when roll < 0.05 + 0.95 * pa then 'win' else 'loss' end;
    ea := 1 / (1 + power(10::numeric, (b.rating - a.rating) / 400.0));
    d := round(16 * (case outa when 'win' then 1 when 'loss' then 0 else 0.5 end - ea))::int;
    update battle_bot_ratings set
      rating = greatest(minr, rating + d),
      games = games + 1, sim_games = sim_games + 1, wins = wins + (outa = 'win')::int, losses = losses + (outa = 'loss')::int, draws = draws + (outa = 'draw')::int
    where season = s and name = a.name;
    update battle_bot_ratings set
      rating = greatest(minr, rating - d),
      games = games + 1, sim_games = sim_games + 1, wins = wins + (outa = 'loss')::int, losses = losses + (outa = 'win')::int, draws = draws + (outa = 'draw')::int
    where season = s and name = b.name;
    update battle_bot_ratings set peak_rating = greatest(peak_rating, rating) where season = s and name in (a.name, b.name);
    done := done + 1;
  end loop;
  return done;
end $$;

-- cron 每分鐘叫一次：asap 的日子每次打 1000 場；其他日子在 from_t～until_t 之間把剩下的場數平均分到剩下的分鐘
create or replace function public.battle_bot_sim_cron() returns void
language plpgsql security definer set search_path = public as $$
declare
  now_l timestamp := battle_local();
  d     public.battle_bot_sim_days;
  left_slots int;
  n     int;
begin
  insert into battle_bot_sim_days (day) values (now_l::date) on conflict (day) do nothing;
  select * into d from battle_bot_sim_days where day = now_l::date for update;
  if d.played >= d.target then return; end if;
  if d.asap then
    n := least(d.target - d.played, 1000);
  else
    if now_l::time < d.from_t or now_l::time >= d.until_t then return; end if;
    -- 剩下幾分鐘（含這一次）
    left_slots := greatest(1, ceil(extract(epoch from (d.until_t - now_l::time)) / 60.0)::int);
    n := least(d.target - d.played, ceil((d.target - d.played)::numeric / left_slots)::int);
  end if;
  n := battle_bot_sim(n);
  update battle_bot_sim_days set played = played + n where day = d.day;
  delete from battle_bot_sim_days where day < now_l::date - 30;
end $$;

revoke all on function public.battle_bot_sim(int), public.battle_bot_sim_cron() from public, anon, authenticated;

-- 電腦跟真人打排位賽時有多強（取代 battle_ranked.sql 的 battle_bot_target、battle_bot_ms）。
-- 基準是「真人在這個難度的題目上的平均」：最近 300 個真人作答（排位、房間都算，電腦的不算），
-- 題目等級＝電腦積分對應的單字等級（900 分第 1 級…1400 分以上第 6 級，和 18 題程度測驗同一份單字分級）。
-- 越高段位電腦讓得越少，同學會停在符合自己程度的分數：
--   電腦積分 1100 以下：答對率＝真人平均 − 5%，答題時間＝真人平均 + 0.5 秒
--   1100–1199：答對率和時間都等於真人平均
--   1200–1399：答對率＝真人平均 + 5%，時間等於真人平均
--   1400 以上：回到原本的段位答對率和段位答題時間
--   不管哪一段，答對率都不超過段位原本的值；同學連輸 3 場以上再 −5%；範圍 30%–97%。
--   真人作答不到 50 個時，答對率當作 60%、時間當作 5 秒。
-- 優質霸王不在電腦名單裡、不參加互打；它的積分是配到的真人積分隨機 ±50（battle_boss_rating），
-- 答對率另外 ×1.1、時間 ×0.9（battle_start 原本就有），畫面上照舊顯示「扛不住」、9999。

-- 真人在第 p_lv 級單字上最近 300 次作答：答對率、平均時間（沒作答算答錯、算整題時間）、作答數
create or replace function public.battle_human_avg(p_lv int, out acc numeric, out ms numeric, out n int)
language sql stable security definer set search_path = public as $$
  select avg(ok::int), avg(t), count(*)::int from (
    select ok, t from (
      select coalesce(rr.p1_pick = rr.answer, false) as ok, coalesce(rr.p1_ms, (battle_rules()->>'round_ms')::int) as t, rr.closed_at
      from battle_rounds rr join battle_words w on w.term = rr.term
      where w.lv = p_lv and rr.closed_at is not null
      union all
      select coalesce(rr.p2_pick = rr.answer, false), coalesce(rr.p2_ms, (battle_rules()->>'round_ms')::int), rr.closed_at
      from battle_rounds rr join battle_matches mm on mm.id = rr.match_id join battle_words w on w.term = rr.term
      where mm.p2 is not null and w.lv = p_lv and rr.closed_at is not null
    ) x order by closed_at desc limit 300
  ) y
$$;
revoke all on function public.battle_human_avg(int) from public, anon, authenticated;

-- 這位同學現在這場（或剛配到的）電腦的積分；找不到就用同學自己的積分
create or replace function public.battle_bot_rating_for(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select m.bot_rating from battle_matches m
     where m.p1 = p_user and m.p2 is null and m.rated and m.code is null and m.status in ('waiting', 'playing')
     order by m.created_at desc limit 1),
    (select rating from battle_ratings where user_id = p_user and season = battle_season()),
    1200)
$$;
revoke all on function public.battle_bot_rating_for(uuid) from public, anon, authenticated;

create or replace function public.battle_bot_target(p_user uuid) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  br  int := battle_bot_rating_for(p_user);
  t   jsonb := battle_tier_info(br);
  st  int := (select bot_streak from battle_ratings where user_id = p_user and season = battle_season());
  h   record;
  a   numeric;
begin
  if br >= 1400 then
    a := (t->>'bot')::numeric;
  else
    select * into h from battle_human_avg(battle_word_level(br));
    if coalesce(h.n, 0) < 50 then h.acc := 0.60; end if;
    a := least((t->>'bot')::numeric, h.acc + case when br < 1100 then -0.05 when br < 1200 then 0 else 0.05 end);
  end if;
  if coalesce(st, 0) <= -3 then a := a - 0.05; end if;
  return least(0.97, greatest(0.30, a));
end $$;

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
  slow numeric := (rules->>'round_ms')::numeric - 1000;
  br  int := battle_bot_rating_for(p_user);
  h   record;
  recent numeric;
  shift numeric := 0;
  c   numeric;
  x   numeric;
begin
  if br < 1400 then
    select * into h from battle_human_avg(battle_word_level(br));
    if coalesce(h.n, 0) < 50 then h.ms := 5000; end if;
    c := least(slow, greatest(1500, h.ms + case when br < 1100 then 500 else 0 end));
    x := c + sqrt(-2 * ln(greatest(random(), 1e-9))) * cos(2 * pi() * random()) * 600;
    return round(least(slow, greatest(1500, x)))::int;
  end if;
  -- 1400 以上：原本的做法。段位的時間範圍裡取常態分布，再往同學最近 5 題的速度最多移 1 秒
  select avg(coalesce(ms, (rules->>'round_ms')::int)) into recent from (
    select case when mm.p1 = p_user then rr.p1_ms else rr.p2_ms end as ms
    from battle_rounds rr join battle_matches mm on mm.id = rr.match_id
    where (mm.p1 = p_user or mm.p2 = p_user) and rr.closed_at is not null
    order by rr.closed_at desc limit (b->>'speed_recent')::int
  ) q;
  if recent is not null then shift := least(adj, greatest(-adj, recent - mid)); end if;
  for i in 1..10 loop
    x := mid + sqrt(-2 * ln(greatest(random(), 1e-9))) * cos(2 * pi() * random()) * (hi - lo) / 4;
    exit when x between lo and hi;
  end loop;
  return round(least(hi, greatest(lo, x)) + shift)::int;
end $$;

-- battle_find 把電腦換成優質霸王時，霸王的積分改成這位玩家的積分隨機 ±50（不用名單上電腦的積分）
create or replace function public.battle_boss_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.bot_name = battle_boss_name() and old.bot_name is distinct from new.bot_name and new.p2 is null then
    new.bot_rating := greatest((battle_rules()->>'min_rating')::int,
      coalesce((select rating from battle_ratings where user_id = new.p1 and season = coalesce(new.season, battle_season())), 1200)
      + floor(random() * 101)::int - 50);
  end if;
  return new;
end $$;
drop trigger if exists battle_boss_rating on public.battle_matches;
create trigger battle_boss_rating before update of bot_name on public.battle_matches
  for each row execute function public.battle_boss_rating();
revoke all on function public.battle_boss_rating() from public, anon, authenticated;

do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'battle-bot-sim';
end $$;
-- 每分鐘一次（battle_bot_sim_cron 自己判斷今天要不要打、打幾場）
select cron.schedule('battle-bot-sim', '* * * * *', 'select public.battle_bot_sim_cron()');
-- 不在這裡直接打：多打的場數要跑一段時間，SQL Editor 可能逾時讓整份 SQL 失敗；交給 1 分鐘內的排程打
-- select public.battle_bot_sim_cron();

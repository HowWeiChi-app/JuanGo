-- ⚠️ 已經在用的資料庫不要單獨重跑這個檔：它會把 battle_join、battle_quit 等換回最早的版本。
--    真的重跑了，要依序再跑：battle_words.sql → battle_ranked.sql → battle_social.sql → battle_lobby.sql → subscriptions.sql → battle_grants.sql。
-- JuanGo live battles: 5 rounds, same questions, faster right answers score more, the last round counts 1.5x.
-- Run once in Supabase → SQL Editor, then run battle_words.sql.
--
-- The apps only call the battle_* functions granted at the end of this file. Every table has row-level security
-- and no policy, so answers, ratings and scores can't be read or changed directly.

create table if not exists public.battle_players (
  user_id    uuid primary key references auth.users on delete cascade,
  name       text not null,
  rating     int  not null,
  games      int  not null default 0,
  wins       int  not null default 0,
  losses     int  not null default 0,
  draws      int  not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.battle_words (
  term     text primary key,
  lv       smallint not null check (lv between 1 and 6),
  pos      text not null default '',
  zh       text not null,
  meanings text[] not null
);
create index if not exists battle_words_lv on public.battle_words (lv);

create table if not exists public.battle_matches (
  id          uuid primary key default gen_random_uuid(),
  code        text unique,                 -- friend matches only
  rated       boolean not null,
  status      text not null default 'waiting' check (status in ('waiting', 'playing', 'finished')),
  p1          uuid not null references auth.users on delete cascade,
  p2          uuid references auth.users on delete cascade,
  p1_seen     timestamptz not null default now(),
  p2_seen     timestamptz not null default now(),
  round       smallint not null default 0,
  p1_score    int not null default 0,
  p2_score    int not null default 0,
  winner      uuid,
  reason      text,                        -- score | left | abandoned
  p1_delta    int not null default 0,
  p2_delta    int not null default 0,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists battle_matches_p1 on public.battle_matches (p1, status);
create index if not exists battle_matches_p2 on public.battle_matches (p2, status);

create table if not exists public.battle_rounds (
  match_id  uuid not null references public.battle_matches on delete cascade,
  n         smallint not null check (n between 1 and 5),
  term      text not null,
  zh        text not null,
  to_zh     boolean not null,              -- true: English prompt, Chinese options
  prompt    text not null,
  options   text[] not null,
  answer    smallint not null,
  starts_at timestamptz,
  ends_at   timestamptz,
  closed_at timestamptz,
  p1_pick   smallint, p1_ms int, p1_points int not null default 0,
  p2_pick   smallint, p2_ms int, p2_points int not null default 0,
  primary key (match_id, n)
);

-- Computer opponents: a match with no p2 is played against the rating and name stored here,
-- and each round holds the answer the computer will give and when.
alter table public.battle_matches add column if not exists bot_name text;
alter table public.battle_matches add column if not exists bot_rating int;
alter table public.battle_rounds add column if not exists bot_pick smallint;
alter table public.battle_rounds add column if not exists bot_ms int;

create table if not exists public.battle_queue (
  user_id   uuid primary key references auth.users on delete cascade,
  rating    int not null,
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  match_id  uuid references public.battle_matches on delete cascade
);

alter table public.battle_players enable row level security;
alter table public.battle_words   enable row level security;
alter table public.battle_matches enable row level security;
alter table public.battle_rounds  enable row level security;
alter table public.battle_queue   enable row level security;

-- ------------------------------------------------------------------ rules

-- Six ranks, one per word level, 200 points each: 400 is 第 3 級 (高一), 1000 and up is 第 6 級.
create or replace function public.battle_tier(r int) returns int
language sql immutable set search_path = public as $$
  select greatest(1, least(6, floor(r / 200.0)::int + 1))
$$;

-- Stands in for the computer wherever a winner's id is needed.
create or replace function public.battle_bot_id() returns uuid
language sql immutable set search_path = public as $$
  select '00000000-0000-0000-0000-000000000000'::uuid
$$;

-- A right answer is worth 100 at once, falling to 50 at the 10-second limit; round 5 counts 1.5x.
create or replace function public.battle_points(n int, ms int) returns int
language sql immutable set search_path = public as $$
  -- 100 points falling to 30 along a curve, steepest at the start, so quick answers rarely tie
  select round((30 + 70 * power(1 - least(greatest(ms, 0), 10000) / 10000.0, 2)) * (case when n = 5 then 1.5 else 1 end))::int
$$;

-- Elo. New players move twice as fast for their first 20 games.
create or replace function public.battle_delta(mine int, other int, games int, result numeric) returns int
language sql immutable set search_path = public as $$
  select round((case when games < 20 then 40 else 20 end) * (result - 1 / (1 + power(10, (other - mine) / 400.0))))::int
$$;

create or replace function public.battle_ms(t timestamptz) returns bigint
language sql immutable set search_path = public as $$
  select (extract(epoch from t) * 1000)::bigint
$$;

create or replace function public.battle_new_name() returns text
language sql volatile set search_path = public as $$
  select (array['勇敢的','安靜的','快樂的','認真的','聰明的','好奇的','溫柔的','機靈的'])[1 + floor(random() * 8)::int]
      || (array['水獺','石虎','黑熊','貓頭鷹','海豚','藍鵲','穿山甲','梅花鹿'])[1 + floor(random() * 8)::int]
      || lpad(floor(random() * 100)::int::text, 2, '0')
$$;

-- A computer opponent's name: the kind of nickname people pick for themselves, never a generated one with a number,
-- and never one a real player already uses.
create or replace function public.battle_bot_name() returns text
language sql volatile set search_path = public as $$
  select n from unnest(array[
    'Kevin','Amy','Jason','Ethan','Chloe','Ian','Vivian','Leo','Grace','Ryan','Annie','Max','Yuki','Eric','Joyce',
    'Wendy','Alan','Iris','Daniel','Sandy','小安','阿哲','柚子','布丁','小熊','阿凱','芋圓','小魚','豆花','阿翔',
    '小米','阿誠','奶茶','湯圓','小葵','阿宏','小晴','麻糬','阿瑋','小宇','睡不飽','想放假','背單字中','學測加油',
    '英文好難','今天也要讀書','高三生存中','單字狂','早八戰士','考前衝刺','三分鐘熱度','珍奶續命','不想早起','讀書好累'
  ]) as n
  where not exists (select 1 from battle_players p where lower(p.name) = lower(n))
  order by random() limit 1
$$;

-- Creates the caller's player on first use. p_level is the 18-question level test's result, or null when the
-- app hasn't had the test done yet. The first time a level comes in it is recorded, and the rating is raised to
-- that level's start if it was lower (players from before the test was required started from 第 3 級).
alter table public.battle_players add column if not exists placed_level smallint;

create or replace function public.battle_start_rating(p_level int) returns int
language sql immutable set search_path = public as $$
  select greatest(100, 200 * (least(6, greatest(1, coalesce(p_level, 3))) - 1))
$$;

create or replace function public.battle_player(p_level int) returns public.battle_players
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  -- greatest() skips nulls, so an untested player (null) has to be kept null by hand
  lv int := case when p_level is null then null else least(6, greatest(1, p_level)) end;
  p  public.battle_players;
begin
  if me is null then raise exception '請先登入'; end if;
  insert into battle_players (user_id, name, rating, placed_level)
  values (me, battle_new_name(), battle_start_rating(lv), lv)
  on conflict (user_id) do nothing;
  if lv is not null then
    update battle_players set placed_level = lv, rating = greatest(rating, battle_start_rating(lv))
    where user_id = me and placed_level is null;
  end if;
  select * into p from battle_players where user_id = me;
  return p;
end $$;

-- Matching, rooms and joining need the level test done.
create or replace function public.battle_ready(p_level int) returns public.battle_players
language plpgsql security definer set search_path = public as $$
declare p public.battle_players := battle_player(p_level);
begin
  if p.placed_level is null then raise exception '請先完成 18 題程度測驗'; end if;
  return p;
end $$;

-- ------------------------------------------------------------------ starting a match

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

  -- three wrong answers from the same level, same part of speech first, none meaning the same thing
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

-- Rounds 1-3 are at the pair's rank, the last two one level harder.
create or replace function public.battle_start(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  m public.battle_matches;
  t timestamptz := clock_timestamp();
  tier int;
begin
  select * into m from battle_matches where id = p_match for update;
  select battle_tier(round(avg(x))::int) into tier from (
    select rating as x from battle_players where user_id in (m.p1, m.p2)
    union all select m.bot_rating where m.bot_rating is not null
  ) r;
  for i in 1..5 loop
    perform battle_make_round(p_match, i, case when i <= 3 then tier else least(6, tier + 1) end);
  end loop;
  if m.bot_rating is not null then
    -- the computer is right about 2 times in 3, and each answer time is drawn from a normal
    -- distribution centred on 4 seconds (sd 1.2 s), kept between 1.5 and 8 seconds
    update battle_rounds b set
      bot_pick = case when random() < 0.65 then b.answer
                      else (b.answer + 1 + floor(random() * 3)::int) % 4 end,
      bot_ms = least(8000, greatest(1500, round(4000 + 1200 * sqrt(-2 * ln(greatest(random(), 1e-9))) * cos(2 * pi() * random()))))::int
    from (
      select r.n, m.bot_rating / 200.0 + 1 - w.lv as edge, battle_tier(m.bot_rating) as skill
      from battle_rounds r join battle_words w on w.term = r.term where r.match_id = p_match
    ) g
    where b.match_id = p_match and b.n = g.n;
  end if;
  update battle_rounds set starts_at = t + interval '4 seconds', ends_at = t + interval '14 seconds'
  where match_id = p_match and n = 1;
  update battle_matches set status = 'playing', round = 1, p1_seen = t, p2_seen = t where id = p_match;
end $$;

-- Looks for an opponent; the app calls this about once a second while waiting.
create or replace function public.battle_find(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me     public.battle_players := battle_ready(p_level);
  t      timestamptz := clock_timestamp();
  q      public.battle_queue;
  other  public.battle_queue;
  active uuid;
  width  int;
  waited int;
  counts boolean;
  mid    uuid;
begin
  -- an unfinished match comes first: reopening the app returns to it
  for active in select id from battle_matches where status = 'playing' and me.user_id in (p1, p2) loop
    perform battle_advance(active);
    if exists (select 1 from battle_matches where id = active and status = 'playing') then
      delete from battle_queue where user_id = me.user_id;
      return jsonb_build_object('match', active);
    end if;
  end loop;

  insert into battle_queue (user_id, rating, joined_at, last_seen) values (me.user_id, me.rating, t, t)
  on conflict (user_id) do update
    set rating = excluded.rating, last_seen = t,
        joined_at = case when battle_queue.last_seen < t - interval '5 seconds' then t else battle_queue.joined_at end
  returning * into q;

  if q.match_id is not null then
    -- matched while waiting; a match that already ended is left over from an earlier search
    if exists (select 1 from battle_matches where id = q.match_id and status = 'playing') then
      delete from battle_queue where user_id = me.user_id;
      return jsonb_build_object('match', q.match_id);
    end if;
    update battle_queue set match_id = null, joined_at = t where user_id = me.user_id returning * into q;
  end if;

  delete from battle_queue where last_seen < t - interval '30 seconds';

  -- a real player always comes first: the rating window opens by 50 a second, and after 8 seconds anyone will do
  waited := floor(extract(epoch from t - q.joined_at))::int;
  width := case when waited >= 8 then 100000 else 100 + 50 * waited end;
  select * into other from battle_queue o
  where o.user_id <> me.user_id and o.match_id is null and o.last_seen > t - interval '4 seconds'
    and abs(o.rating - me.rating) <= width
  order by abs(o.rating - me.rating), o.joined_at
  limit 1 for update skip locked;

  if not found then
    -- nobody else is here: play the computer, at about the caller's own rating. It isn't announced: it gets a
    -- player-style name, and the wait before it differs from search to search (6 to 12 seconds).
    if waited < 6 + abs(hashtext(me.user_id::text || q.joined_at::text)) % 7 then
      return jsonb_build_object('match', null, 'waited', waited);
    end if;
    insert into battle_matches (rated, p1, bot_name, bot_rating)
    values (true, me.user_id, coalesce(battle_bot_name(), battle_new_name()), greatest(100, me.rating + floor(random() * 121)::int - 60))
    returning id into mid;
    perform battle_start(mid);
    delete from battle_queue where user_id = me.user_id;
    return jsonb_build_object('match', mid);
  end if;

  -- a pair counts toward ratings three times a day at most, so two friends can't farm points
  select count(*) < 3 into counts from battle_matches
  where rated and status = 'finished' and finished_at > t - interval '1 day'
    and ((p1 = me.user_id and p2 = other.user_id) or (p1 = other.user_id and p2 = me.user_id));

  insert into battle_matches (rated, p1, p2) values (counts, other.user_id, me.user_id) returning id into mid;
  perform battle_start(mid);
  update battle_queue set match_id = mid where user_id = other.user_id;
  delete from battle_queue where user_id = me.user_id;
  return jsonb_build_object('match', mid);
end $$;

create or replace function public.battle_cancel_find() returns void
language sql security definer set search_path = public as $$
  delete from public.battle_queue where user_id = auth.uid() and match_id is null
$$;

-- Friend match: makes a room with a 6-character code. Friend matches never change ratings.
create or replace function public.battle_create_room(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.battle_players := battle_ready(p_level);
  c  text;
  mid uuid;
begin
  update battle_matches set status = 'finished', reason = 'abandoned', finished_at = clock_timestamp()
  where p1 = me.user_id and status = 'waiting';
  loop
    c := left(new_share_code(), 6);
    begin
      insert into battle_matches (code, rated, p1) values (c, false, me.user_id) returning id into mid;
      exit;
    exception when unique_violation then null;
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
  select * into m from battle_matches
  where code = upper(replace(trim(p_code), '-', '')) and status = 'waiting' for update;
  if not found or m.p1_seen < clock_timestamp() - interval '15 seconds' then
    raise exception '找不到這個房間，請朋友重新建立';
  end if;
  if m.p1 = me.user_id then raise exception '這是你自己建立的房間'; end if;
  update battle_matches set p2 = me.user_id where id = m.id;
  perform battle_start(m.id);
  return jsonb_build_object('match', m.id);
end $$;

-- ------------------------------------------------------------------ playing

create or replace function public.battle_finish(p_match uuid, p_winner uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare
  m  public.battle_matches;
  a  public.battle_players;
  b  public.battle_players;
  s1 numeric := case when p_winner is null then 0.5 else 0 end;
  d1 int := 0;
  d2 int := 0;
begin
  select * into m from battle_matches where id = p_match for update;
  if m.status = 'finished' then return; end if;
  if m.rated and p_reason <> 'abandoned' then
    perform 1 from battle_players where user_id in (m.p1, m.p2) order by user_id for update;
    select * into a from battle_players where user_id = m.p1;
    select * into b from battle_players where user_id = m.p2;
    if p_winner = m.p1 then s1 := 1; end if;
    d1 := battle_delta(a.rating, coalesce(b.rating, m.bot_rating), a.games, s1);
    if m.p2 is not null then d2 := battle_delta(b.rating, a.rating, b.games, 1 - s1); end if;
    update battle_players set rating = greatest(100, rating + d1), games = games + 1,
      wins = wins + (s1 = 1)::int, losses = losses + (s1 = 0)::int, draws = draws + (s1 = 0.5)::int
    where user_id = m.p1;
    update battle_players set rating = greatest(100, rating + d2), games = games + 1,
      wins = wins + (s1 = 0)::int, losses = losses + (s1 = 1)::int, draws = draws + (s1 = 0.5)::int
    where user_id = m.p2;
  end if;
  update battle_matches set status = 'finished', winner = p_winner, reason = p_reason,
    p1_delta = d1, p2_delta = d2, finished_at = clock_timestamp()
  where id = p_match;
end $$;

-- Moves a match forward. There is no background job: every state request and answer runs this.
create or replace function public.battle_advance(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  m public.battle_matches;
  r public.battle_rounds;
  t timestamptz := clock_timestamp();
  gone1 boolean;
  gone2 boolean;
  closed timestamptz;
  next_start timestamptz;
  s1 int;
  s2 int;
begin
  select * into m from battle_matches where id = p_match for update;
  if not found or m.status <> 'playing' then return; end if;

  gone1 := m.p1_seen < t - interval '12 seconds';
  gone2 := m.p2 is not null and m.p2_seen < t - interval '12 seconds';
  if gone1 and gone2 then perform battle_finish(p_match, null, 'abandoned'); return; end if;
  if gone1 then perform battle_finish(p_match, coalesce(m.p2, battle_bot_id()), 'left'); return; end if;
  if gone2 then perform battle_finish(p_match, m.p1, 'left'); return; end if;

  select * into r from battle_rounds where match_id = p_match and n = m.round for update;
  -- the computer's answer lands when its time comes
  if m.p2 is null and r.closed_at is null and r.p2_pick is null and t >= r.starts_at + r.bot_ms * interval '1 millisecond' then
    update battle_rounds set p2_pick = r.bot_pick, p2_ms = r.bot_ms,
      p2_points = case when r.bot_pick = r.answer then battle_points(r.n, r.bot_ms) else 0 end
    where match_id = p_match and n = r.n
    returning * into r;
  end if;
  if r.closed_at is not null or not (t >= r.ends_at or (r.p1_pick is not null and r.p2_pick is not null)) then return; end if;

  closed := least(t, r.ends_at);
  update battle_rounds set closed_at = closed where match_id = p_match and n = m.round;
  s1 := m.p1_score + r.p1_points;
  s2 := m.p2_score + r.p2_points;
  update battle_matches set p1_score = s1, p2_score = s2 where id = p_match;

  if m.round = 5 then
    perform battle_finish(p_match, case when s1 > s2 then m.p1 when s2 > s1 then coalesce(m.p2, battle_bot_id()) end, 'score');
  else
    -- three seconds to see the answer, and always time for the next poll to fetch the question
    next_start := greatest(closed + interval '3 seconds', t + interval '1500 milliseconds');
    update battle_rounds set starts_at = next_start, ends_at = next_start + interval '10 seconds'
    where match_id = p_match and n = m.round + 1;
    update battle_matches set round = round + 1 where id = p_match;
  end if;
end $$;

-- Everything the caller's screen needs. The right answer is only included once a round has closed.
create or replace function public.battle_view(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me   uuid := auth.uid();
  t    timestamptz := clock_timestamp();
  m    public.battle_matches;
  r    public.battle_rounds;
  l    public.battle_rounds;
  mine public.battle_players;
  opp  public.battle_players;
  first boolean;
  res  jsonb := jsonb_build_object('now', battle_ms(t));
begin
  select * into m from battle_matches where id = p_match;
  if not found or me not in (m.p1, coalesce(m.p2, m.p1)) then raise exception '找不到這場對戰'; end if;
  first := me = m.p1;
  select * into mine from battle_players where user_id = me;
  select * into opp from battle_players where user_id = case when first then m.p2 else m.p1 end;

  res := res || jsonb_build_object(
    'id', m.id, 'status', m.status, 'rated', m.rated, 'code', m.code, 'round', m.round,
    'you', jsonb_build_object('name', mine.name, 'rating', mine.rating, 'tier', battle_tier(mine.rating),
                              'score', case when first then m.p1_score else m.p2_score end),
    'opponent', case when opp.user_id is null and m.bot_rating is null then null else jsonb_build_object(
                              'name', coalesce(opp.name, m.bot_name),
                              'rating', coalesce(opp.rating, m.bot_rating),
                              'tier', battle_tier(coalesce(opp.rating, m.bot_rating)),
                              'score', case when first then m.p2_score else m.p1_score end) end);

  select * into r from battle_rounds where match_id = m.id and n = m.round;
  if m.status = 'playing' then
    res := res || jsonb_build_object('starts', battle_ms(r.starts_at), 'ends', battle_ms(r.ends_at),
      'answered', (case when first then r.p1_pick else r.p2_pick end) is not null,
      'opponent_answered', (case when first then r.p2_pick else r.p1_pick end) is not null);
    if t >= r.starts_at - interval '1 second' then
      res := res || jsonb_build_object('question', jsonb_build_object(
        'n', r.n, 'to_zh', r.to_zh, 'prompt', r.prompt, 'options', to_jsonb(r.options)));
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
    res := res || jsonb_build_object('result', jsonb_build_object(
      'outcome', case when m.winner is null then 'draw' when m.winner = me then 'win' else 'loss' end,
      'reason', m.reason,
      'delta', case when first then m.p1_delta else m.p2_delta end,
      'words', coalesce((select jsonb_agg(jsonb_build_object(
          'term', x.term, 'zh', x.zh,
          'right', (case when first then x.p1_pick else x.p2_pick end) is not distinct from x.answer) order by x.n)
        from battle_rounds x where x.match_id = m.id and x.closed_at is not null), '[]'::jsonb)));
  end if;
  return res;
end $$;

-- The screen polls this about twice a second during a match.
create or replace function public.battle_state(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t  timestamptz := clock_timestamp();
begin
  update battle_matches set
    p1_seen = case when p1 = me then t else p1_seen end,
    p2_seen = case when p2 = me then t else p2_seen end
  where id = p_match and status <> 'finished' and me in (p1, p2);
  perform battle_advance(p_match);
  return battle_view(p_match);
end $$;

-- p_ms is the time the phone measured. It is trusted only within one second of what the server saw,
-- which makes up for a slow connection without letting anyone claim an instant answer.
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
    pts := case when p_pick = r.answer then battle_points(r.n, ms) else 0 end;
    if first then
      update battle_rounds set p1_pick = p_pick, p1_ms = ms, p1_points = pts where match_id = p_match and n = r.n;
    else
      update battle_rounds set p2_pick = p_pick, p2_ms = ms, p2_points = pts where match_id = p_match and n = r.n;
    end if;
  end if;
  return battle_state(p_match);
end $$;

-- Leaving a room closes it; leaving a running match loses it.
create or replace function public.battle_quit(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  public.battle_matches;
begin
  select * into m from battle_matches where id = p_match for update;
  if not found or me not in (m.p1, coalesce(m.p2, m.p1)) then return; end if;
  if m.status = 'waiting' then perform battle_finish(p_match, null, 'abandoned');
  elsif m.status = 'playing' then
    perform battle_finish(p_match, case when me = m.p1 then coalesce(m.p2, battle_bot_id()) else m.p1 end, 'left');
  end if;
end $$;

create or replace function public.battle_me(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p public.battle_players := battle_player(p_level);
begin
  return jsonb_build_object('name', p.name, 'rating', p.rating, 'tier', battle_tier(p.rating),
                            'games', p.games, 'wins', p.wins, 'losses', p.losses, 'draws', p.draws);
end $$;

-- Lets a player choose the name opponents see.
create or replace function public.battle_set_name(p_name text, p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.battle_players := battle_player(p_level);
  clean text := btrim(regexp_replace(coalesce(p_name, ''), '[[:space:]　]+', ' ', 'g'));
begin
  if char_length(clean) not between 2 and 12 then raise exception '名稱要 2 到 12 個字'; end if;
  if clean ~ '[[:cntrl:]]' or clean ~ U&'[\200B-\200F\202A-\202E\2060-\2069\FEFF]' then
    raise exception '名稱有不能使用的字元';
  end if;
  perform pg_advisory_xact_lock(hashtext('battle_set_name'));
  if exists (select 1 from battle_players where lower(name) = lower(clean) and user_id <> me.user_id) then
    raise exception '這個名稱已經有人使用';
  end if;
  update battle_players set name = clean where user_id = me.user_id;
  return battle_me(p_level);
end $$;

-- ------------------------------------------------------------------ access

revoke all on public.battle_players, public.battle_words, public.battle_matches, public.battle_rounds,
  public.battle_queue from public, anon, authenticated;

do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'battle\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

grant execute on function public.battle_me(int), public.battle_set_name(text, int), public.battle_find(int), public.battle_cancel_find(),
  public.battle_create_room(int), public.battle_join(text, int), public.battle_state(uuid),
  public.battle_answer(uuid, int, int, int), public.battle_quit(uuid) to authenticated;

-- 上面的迴圈也會收回後面幾個檔（battle_ranked／battle_social／battle_lobby）的函式，
-- 重跑這個檔時把 App 會呼叫的還回去（和 battle_grants.sql 同一份清單；還沒建立的函式自動跳過）
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             'battle_rematch', 'battle_board', 'battle_report', 'battle_block', 'battle_blocked', 'battle_unblock',
             'battle_set_hidden', 'battle_dev_limit', 'battle_retest_done',
             'battle_room_add_bot', 'battle_room_set_public', 'battle_public_rooms', 'battle_join_public',
             'battle_add_friend', 'battle_remove_friend', 'battle_friend_list', 'battle_tier_detail',
             'battle_room_state', 'battle_room_ready', 'battle_room_start', 'battle_room_kick',
             'battle_room_invite', 'battle_my_invites', 'battle_invite_dismiss', 'battle_room_invited'])
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

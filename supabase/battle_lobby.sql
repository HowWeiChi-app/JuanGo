-- 房間等候室：房客加入後先「準備」，房主再按「開始」；房主可以請房客離開；房主可以在 App 裡邀請好友。
-- 在 battle_social.sql 之後執行（可以重複執行，不動舊資料）。
--
-- 改變的行為：
-- * battle_join 不再一加入就開打，而是把房客放進房間（p2），狀態仍是 waiting。
-- * battle_quit 由房客呼叫時只是離開房間，房間留給房主；房主呼叫才關閉房間。
-- * 「再來一場」（battle_rematch）不受影響，仍是後按的人一按就開始。
-- * 加入電腦：電腦先坐進房間（算已準備），房主按「開始」才開打；房主可以請電腦離開。

alter table public.battle_matches add column if not exists p2_ready boolean not null default false;
alter table public.battle_matches add column if not exists kicked uuid[] not null default '{}';

-- ------------------------------------------------------------------ 加入、離開
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
  if me.user_id = any(m.kicked) then raise exception '房主請你離開了這個房間'; end if;
  if m.bot_rating is not null and m.status = 'waiting' then raise exception '房間裡已經有電腦了'; end if;
  -- 房客 15 秒沒有回應就當作已經離開，位子讓給新來的人
  if m.p2 is not null and m.p2 <> me.user_id and m.p2_seen >= clock_timestamp() - interval '15 seconds' then
    raise exception '房間已經有人了';
  end if;
  update battle_matches set p2 = me.user_id, p2_ready = false, p2_seen = clock_timestamp() where id = m.id;
  delete from battle_invites where match_id = m.id and to_user = me.user_id;
  return jsonb_build_object('match', m.id, 'lobby', true);
end $$;

-- 房客離開等候室：房間留給房主。房主離開或對戰中離開照舊（關閉房間／判輸）。
create or replace function public.battle_quit(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  public.battle_matches;
begin
  select * into m from battle_matches where id = p_match for update;
  if not found or me not in (m.p1, coalesce(m.p2, m.p1)) then return; end if;
  if m.status = 'waiting' and me = m.p2 and me <> m.p1 then
    update battle_matches set p2 = null, p2_ready = false where id = m.id;
  elsif m.status = 'waiting' then perform battle_finish(p_match, null, 'abandoned');
  elsif m.status = 'playing' then
    perform battle_finish(p_match, case when me = m.p1 then coalesce(m.p2, battle_bot_id()) else m.p1 end, 'left');
  end if;
end $$;

-- ------------------------------------------------------------------ 等候室
-- 等候室裡兩邊都輪詢這個（約每 0.5 秒）：battle_state 的內容，再加上 lobby（房客準備了沒、自己是不是房主）。
-- 被請離開的房客會收到「房主請你離開了這個房間」。
create or replace function public.battle_room_state(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  m   public.battle_matches;
  res jsonb;
begin
  select * into m from battle_matches where id = p_match;
  if not found then raise exception '找不到這場對戰'; end if;
  if m.status = 'waiting' and me = any(m.kicked) and me is distinct from m.p2 and me <> m.p1 then
    raise exception '房主請你離開了這個房間';
  end if;
  if m.status = 'waiting' and me <> m.p1 and me is distinct from m.p2 then
    raise exception '你已經離開這個房間';
  end if;
  -- 房客關掉 App 沒有按離開：15 秒沒回應就讓出位子
  if m.status = 'waiting' and m.p2 is not null and m.p2 <> me
     and m.p2_seen < clock_timestamp() - interval '15 seconds' then
    update battle_matches set p2 = null, p2_ready = false where id = m.id;
  end if;
  res := battle_state(p_match);
  select * into m from battle_matches where id = p_match;
  return res || jsonb_build_object('lobby', jsonb_build_object(
    'host', m.p1 = me,
    -- 房間裡的電腦一進來就算準備好了
    'ready', m.p2_ready or (m.p2 is null and m.bot_rating is not null),
    'guest', m.p2 is not null or m.bot_rating is not null));
end $$;

create or replace function public.battle_room_ready(p_match uuid, p_ready boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  update battle_matches set p2_ready = coalesce(p_ready, false)
  where id = p_match and p2 = auth.uid() and status = 'waiting';
  if not found then raise exception '你已經不在這個房間了'; end if;
end $$;

create or replace function public.battle_room_start(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m public.battle_matches;
begin
  select * into m from battle_matches where id = p_match for update;
  if not found or m.p1 <> auth.uid() or m.status <> 'waiting' then raise exception '找不到這個房間'; end if;
  -- 房間裡是電腦：房主按「開始」就開打
  if m.p2 is null and m.bot_rating is not null then
    update battle_matches set is_public = false where id = m.id;
    perform battle_start(m.id);
    return jsonb_build_object('match', m.id);
  end if;
  if m.p2 is null or m.p2_seen < clock_timestamp() - interval '15 seconds' then
    raise exception '房客已經離開了';
  end if;
  if not m.p2_ready then raise exception '房客還沒準備好'; end if;
  update battle_matches set is_public = false where id = m.id;
  perform battle_start(m.id);
  return jsonb_build_object('match', m.id);
end $$;

-- 房主請房客離開：這個人之後不能再用代碼加入這個房間。房間裡是電腦時就把電腦移走
create or replace function public.battle_room_kick(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update battle_matches set bot_name = null, bot_rating = null
  where id = p_match and p1 = auth.uid() and status = 'waiting' and p2 is null and bot_rating is not null;
  if found then return; end if;
  update battle_matches set kicked = array_append(kicked, p2), p2 = null, p2_ready = false
  where id = p_match and p1 = auth.uid() and status = 'waiting' and p2 is not null;
end $$;

-- 房間裡已經有房客時不能加電腦（原本的版本只看 p2，這裡把錯誤訊息講清楚）。
-- 電腦加入後不會馬上開始，跟真人房客一樣等房主按「開始」。
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
  if m.status <> 'waiting' then raise exception '房間已經開始了'; end if;
  if m.p2 is not null then raise exception '房間裡已經有朋友了，請他離開才能加入電腦'; end if;
  if m.bot_rating is not null then return jsonb_build_object('match', m.id); end if;
  r := (battle_rating(me)).rating;
  update battle_matches set
    bot_name = coalesce(battle_bot_name(me), battle_new_name()),
    bot_rating = greatest((rules->>'min_rating')::int, r + floor(random() * (2 * spread + 1))::int - spread),
    is_public = false
  where id = m.id;
  -- 電腦先坐進房間，房主按「開始」（battle_room_start）才開打
  return jsonb_build_object('match', m.id, 'lobby', true);
end $$;

-- 有房客時也能切換公開／私人
create or replace function public.battle_room_set_public(p_match uuid, p_public boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update battle_matches set is_public = coalesce(p_public, false)
  where id = p_match and p1 = auth.uid() and status = 'waiting' and code is not null;
  if not found then raise exception '找不到這個房間'; end if;
  return jsonb_build_object('public', coalesce(p_public, false));
end $$;

-- ------------------------------------------------------------------ 邀請好友
create table if not exists public.battle_invites (
  id         bigint generated always as identity primary key,
  match_id   uuid not null references public.battle_matches on delete cascade,
  from_user  uuid not null references auth.users on delete cascade,
  to_user    uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  unique (match_id, to_user)
);
create index if not exists battle_invites_to on public.battle_invites (to_user, created_at desc);
alter table public.battle_invites enable row level security;
revoke all on public.battle_invites from public, anon, authenticated;

-- 房主邀請好友（p_pid 是好友代碼／pid）。同一個人再邀請一次只是更新時間。
create or replace function public.battle_room_invite(p_match uuid, p_pid text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  uuid := auth.uid();
  who uuid;
begin
  if not exists (select 1 from battle_matches where id = p_match and p1 = me and status = 'waiting' and code is not null) then
    raise exception '找不到這個房間';
  end if;
  select user_id into who from battle_players where pid = lower(trim(coalesce(p_pid, '')));
  if who is null or not exists (select 1 from battle_friends where user_id = me and friend_id = who) then
    raise exception '只能邀請好友';
  end if;
  if battle_blocked_between(me, who) then raise exception '無法邀請'; end if;
  insert into battle_invites (match_id, from_user, to_user) values (p_match, me, who)
  on conflict (match_id, to_user) do update set created_at = now();
end $$;

-- 收到的邀請：房間還開著、房主 15 秒內還在、還沒有房客、10 分鐘內的邀請
create or replace function public.battle_my_invites() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
    select battle_side(i.from_user, null, null, 0, auth.uid())
           || jsonb_build_object('id', i.id, 'code', m.code, 'at', i.created_at) as x
    from battle_invites i join battle_matches m on m.id = i.match_id
    where i.to_user = auth.uid() and i.created_at >= now() - interval '10 minutes'
      and m.status = 'waiting' and m.code is not null and m.p2 is null and m.bot_rating is null
      and m.p1_seen >= clock_timestamp() - interval '15 seconds'
      and not battle_blocked_between(i.from_user, i.to_user)
    order by i.created_at desc limit 5
  ) s
$$;

create or replace function public.battle_invite_dismiss(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from battle_invites where id = p_id and to_user = auth.uid()
$$;

-- 房主看自己邀請過誰（好友列表上顯示「已邀請」）
create or replace function public.battle_room_invited(p_match uuid) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(p.pid), '[]'::jsonb)
  from battle_invites i join battle_players p on p.user_id = i.to_user
  where i.match_id = p_match and i.from_user = auth.uid()
$$;

-- ------------------------------------------------------------------ 權限
revoke all on function public.battle_join(text, int), public.battle_quit(uuid), public.battle_room_state(uuid),
  public.battle_room_ready(uuid, boolean), public.battle_room_start(uuid), public.battle_room_kick(uuid),
  public.battle_room_add_bot(uuid), public.battle_room_set_public(uuid, boolean),
  public.battle_room_invite(uuid, text), public.battle_my_invites(), public.battle_invite_dismiss(bigint),
  public.battle_room_invited(uuid) from public, anon;
grant execute on function public.battle_join(text, int), public.battle_quit(uuid), public.battle_room_state(uuid),
  public.battle_room_ready(uuid, boolean), public.battle_room_start(uuid), public.battle_room_kick(uuid),
  public.battle_room_add_bot(uuid), public.battle_room_set_public(uuid, boolean),
  public.battle_room_invite(uuid, text), public.battle_my_invites(), public.battle_invite_dismiss(bigint),
  public.battle_room_invited(uuid) to authenticated;

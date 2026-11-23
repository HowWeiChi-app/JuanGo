-- 訂閱狀態（跨平台同步 Pro）。在 battle_ranked.sql、textbook.sql 之後執行，可以重複執行。
--
-- 不登入也能在 App Store／Google Play 購買；登入後，App 把商店交易的 original_transaction_id 交給伺服器，
-- 由伺服器（之後的 RevenueCat webhook 或商店驗證函式，用 service role）寫進 user_subscriptions。
-- 使用者自己不能寫這張表，避免改到期日。
--
-- 商品：
--   juango_pro_monthly / juango_pro_yearly  捲字 Pro（自動續訂）
--   gos_pro_monthly / gos_pro_yearly        GOs PRO（自動續訂，也解鎖捲字 Pro）
--   juango_pass_180                         180 天大考衝刺包 NT$300（iOS 非續訂型、Android 預付方案），天數可疊加
--   juango_tip_mars                         火星贊助者 NT$30（消耗型，只給徽章，不解鎖功能）

create table if not exists public.user_subscriptions (
  id                       bigint generated always as identity primary key,
  user_id                  uuid not null references auth.users on delete cascade,
  product_id               text not null,
  platform                 text not null check (platform in ('app_store', 'play_store', 'promo')),
  kind                     text not null check (kind in ('renewing', 'prepaid', 'tip')),
  original_transaction_id  text not null,
  purchased_at             timestamptz not null default now(),
  expires_at               timestamptz,              -- 續訂型：商店給的到期日；預付型：null（用 days 疊加）
  days                     int,                      -- 預付型的天數（衝刺包 180）
  status                   text not null default 'active' check (status in ('active', 'grace', 'canceled', 'expired', 'refunded')),
  updated_at               timestamptz not null default now(),
  unique (platform, original_transaction_id)
);
create index if not exists user_subscriptions_user on public.user_subscriptions (user_id);
alter table public.user_subscriptions enable row level security;
drop policy if exists "read own subscriptions" on public.user_subscriptions;
create policy "read own subscriptions" on public.user_subscriptions for select using (auth.uid() = user_id);
grant select on public.user_subscriptions to authenticated;

-- 這個帳號的捲字 Pro 到期時間（null = 沒有 Pro）。
-- 續訂型取最晚的到期日；衝刺包依購買順序疊加：每包從「目前算到的到期日」和「購買時間」較晚的那個往後加 days 天，
-- 所以訂閱中買的衝刺包會接在訂閱到期後，到期後才買的從購買當下開始算。
create or replace function public.juango_pro_expires_at(p_user uuid) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare
  v_end timestamptz;
  r record;
begin
  select max(s.expires_at) into v_end from user_subscriptions s
   where s.user_id = p_user and s.kind = 'renewing' and s.status in ('active', 'grace', 'canceled')
     and (s.product_id like 'juango_pro_%' or s.product_id like 'gos_pro_%');
  for r in select s.purchased_at, s.days from user_subscriptions s
            where s.user_id = p_user and s.kind = 'prepaid' and s.status <> 'refunded' and s.days > 0
            order by s.purchased_at, s.id loop
    v_end := greatest(coalesce(v_end, r.purchased_at), r.purchased_at) + make_interval(days => r.days);
  end loop;
  -- 舊的 entitlements（兌換碼、之前的 webhook）也算
  select greatest(v_end, max(e.expires_at)) into v_end from entitlements e
   where e.user_id = p_user and e.entitlement = 'juango_pro' and e.status in ('active', 'grace', 'canceled');
  return case when v_end > now() then v_end end;
end $$;

create or replace function public.gos_pro_expires_at(p_user uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when max(x) > now() then max(x) end from (
    select s.expires_at as x from user_subscriptions s
     where s.user_id = p_user and s.kind = 'renewing' and s.product_id like 'gos_pro_%' and s.status in ('active', 'grace', 'canceled')
    union all
    select e.expires_at from entitlements e
     where e.user_id = p_user and e.entitlement = 'gos_pro' and e.status in ('active', 'grace', 'canceled')
  ) t
$$;

-- 對戰、課文書架、雲端 AI 都用這個判斷 Pro（取代 battle_ranked.sql／textbook.sql 裡只看 entitlements 的版本）
create or replace function public.has_pro(p_user uuid, p_app text default 'juango_pro') returns boolean
language sql stable security definer set search_path = public as $$
  select case p_app
    when 'gos_pro' then gos_pro_expires_at(p_user) is not null
    else juango_pro_expires_at(p_user) is not null
  end
$$;

-- App 讀自己的狀態：{plan: 'gos'|'juango'|null, expires_at, renewing, supporter}
create or replace function public.my_subscription() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_gos timestamptz;
  v_juango timestamptz;
begin
  if me is null then return jsonb_build_object('plan', null); end if;
  v_gos := gos_pro_expires_at(me);
  v_juango := juango_pro_expires_at(me);
  return jsonb_build_object(
    'plan', case when v_gos is not null then 'gos' when v_juango is not null then 'juango' end,
    'expires_at', greatest(v_gos, v_juango),
    'renewing', exists (select 1 from user_subscriptions s where s.user_id = me and s.kind = 'renewing' and s.status in ('active', 'grace')),
    'supporter', exists (select 1 from user_subscriptions s where s.user_id = me and s.kind = 'tip' and s.status <> 'refunded'));
end $$;

revoke all on function public.juango_pro_expires_at(uuid), public.gos_pro_expires_at(uuid) from public, anon, authenticated;
grant execute on function public.my_subscription() to authenticated;

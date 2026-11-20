-- 7. 社群活動「發一篇文，免費用一年」（官網 free-year/、redeem/）。Run once in Supabase → SQL Editor.
-- 只有 Edge Function（service role）讀寫這些表：表都開 RLS 但不開 policy，函式都只授權給 service_role。
-- 審核：在 Dashboard 把 promo_claims.status 從 'pending' 改成 'approved' 或 'rejected'，再呼叫 promo-send 寄信。
-- 兌換碼：App Store Connect／Play Console 下載的 CSV 匯進 promo_codes（app、platform、code）。

-- 活動設定：名額和期間。官網的「還剩 N 名」和表單開關都看這裡。
create table if not exists public.promo_campaigns (
  id        text primary key,                 -- 'social_2026'
  quota     int  not null check (quota >= 0),
  starts_at timestamptz,
  ends_at   timestamptz,
  open      boolean not null default true      -- 手動提前結束：改成 false
);
alter table public.promo_campaigns enable row level security;

create table if not exists public.promo_claims (
  id               uuid primary key default gen_random_uuid(),
  campaign         text not null references public.promo_campaigns on update cascade,
  email            text not null check (char_length(email) <= 254),
  post_url         text not null check (char_length(post_url) <= 300),  -- 已正規化的一般貼文網址，限動不受理
  post_platform    text not null check (post_platform in ('instagram','threads')),
  likes            int  not null check (likes >= 0),
  views            int  not null check (views >= 0),
  app              text not null check (app in ('juango','bango')),      -- 要哪個 App 的 Pro
  device           text not null check (device in ('ios','android')),    -- 申請時填的手機
  proof_image_path text,                                                  -- Storage promo-proofs，選填
  status           text not null default 'pending' check (status in ('pending','approved','rejected','sent','redeemed')),
  review_note      text,
  token_hash       text unique,          -- 啟用連結 token 的 SHA-256（不存 token 本身）
  token_expires_at timestamptz,          -- 寄出後 30 天
  platform         text check (platform in ('ios','android')),           -- 實際拿代碼的平台
  sent_at          timestamptz,
  created_at       timestamptz not null default now(),
  constraint promo_threshold check (likes >= 100 or views >= 10000),
  unique (campaign, email),
  unique (campaign, post_url)
);
create index if not exists promo_claims_status on public.promo_claims (campaign, status, created_at);
alter table public.promo_claims enable row level security;

create table if not exists public.promo_codes (
  code       text primary key,
  platform   text not null check (platform in ('ios','android')),
  app        text not null check (app in ('juango','bango')),
  campaign   text not null default 'social_2026' references public.promo_campaigns on update cascade,
  claimed_by uuid unique references public.promo_claims on delete set null,
  claimed_at timestamptz
);
create index if not exists promo_codes_free on public.promo_codes (campaign, app, platform) where claimed_by is null;
alter table public.promo_codes enable row level security;

-- 防灌水：同一個 IP（只存加鹽的雜湊）每小時的次數
create table if not exists public.promo_hits (
  ip_hash text not null,
  kind    text not null,
  at      timestamptz not null default now()
);
create index if not exists promo_hits_ip on public.promo_hits (ip_hash, kind, at);
alter table public.promo_hits enable row level security;

-- 截圖：私人 bucket，只收圖片、5MB 以內
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('promo-proofs', 'promo-proofs', false, 5242880, array['image/jpeg','image/png','image/heic','image/heif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------- 給 Edge Function 呼叫的函式

-- 目前開放的活動：open、在期間內。沒有就回傳 null。
create or replace function public.promo_current() returns public.promo_campaigns
language sql stable set search_path = public as $$
  select * from promo_campaigns
  where open and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())
  order by starts_at desc nulls last limit 1
$$;

-- 剩餘名額：名額減掉沒被退件的申請
create or replace function public.promo_stats() returns jsonb
language sql stable set search_path = public as $$
  select case when c.id is null then jsonb_build_object('remaining', 0, 'open', false)
    else jsonb_build_object('remaining', greatest(0, c.quota - (select count(*) from promo_claims where campaign = c.id and status <> 'rejected')),
                            'open', true, 'campaign', c.id) end
  from (select (promo_current()).*) c
$$;

-- 記一次並回傳這一小時內還沒超過上限。順便清掉一天以前的紀錄。
create or replace function public.promo_rate_hit(p_ip_hash text, p_kind text, p_limit int) returns boolean
language plpgsql set search_path = public as $$
declare n int;
begin
  delete from promo_hits where at < now() - interval '1 day';
  select count(*) into n from promo_hits where ip_hash = p_ip_hash and kind = p_kind and at > now() - interval '1 hour';
  if n >= p_limit then return false; end if;
  insert into promo_hits (ip_hash, kind) values (p_ip_hash, p_kind);
  return true;
end $$;

-- 新增申請。回傳 'ok'、'duplicate'（同 Email 或同一篇貼文）或 'closed'（沒有開放的活動或名額滿了）。
-- 用 advisory lock 讓同一個活動的申請排隊，名額不會超收。
create or replace function public.promo_apply(
  p_email text, p_post_url text, p_post_platform text, p_likes int, p_views int,
  p_app text, p_device text, p_proof text
) returns text
language plpgsql set search_path = public as $$
declare c promo_campaigns; used int;
begin
  c := promo_current();
  if c.id is null then return 'closed'; end if;
  perform pg_advisory_xact_lock(hashtext('promo:' || c.id));
  if exists (select 1 from promo_claims where campaign = c.id and (email = lower(p_email) or post_url = p_post_url)) then
    return 'duplicate';
  end if;
  select count(*) into used from promo_claims where campaign = c.id and status <> 'rejected';
  if used >= c.quota then return 'closed'; end if;
  insert into promo_claims (campaign, email, post_url, post_platform, likes, views, app, device, proof_image_path)
  values (c.id, lower(p_email), p_post_url, p_post_platform, p_likes, p_views, p_app, p_device, p_proof);
  return 'ok';
exception when unique_violation then
  return 'duplicate';
end $$;

-- 用 token 找申請（兌換頁打開時）。
create or replace function public.promo_claim_lookup(p_token_hash text) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', c.id, 'app', c.app, 'status', c.status, 'expired', c.token_expires_at < now(),
    'code', k.code, 'platform', k.platform)
  from promo_claims c left join promo_codes k on k.claimed_by = c.id
  where c.token_hash = p_token_hash and c.status in ('sent','redeemed')
$$;

-- 發一組代碼。同一個申請只會拿到一組：已經有就回傳那組（already = true）。
-- 回傳 null 代表過期，{"sold_out": true} 代表這個平台的代碼發完了。
create or replace function public.promo_issue_code(p_claim_id uuid, p_platform text) returns jsonb
language plpgsql set search_path = public as $$
declare c promo_claims; k promo_codes;
begin
  select * into c from promo_claims where id = p_claim_id for update;
  if c.id is null then return null; end if;
  select * into k from promo_codes where claimed_by = c.id;
  if k.code is not null then
    return jsonb_build_object('code', k.code, 'platform', k.platform, 'app', c.app, 'already', true);
  end if;
  if c.status <> 'sent' or c.token_expires_at < now() then return null; end if;
  select * into k from promo_codes
  where campaign = c.campaign and app = c.app and platform = p_platform and claimed_by is null
  limit 1 for update skip locked;
  if k.code is null then return jsonb_build_object('sold_out', true); end if;
  update promo_codes set claimed_by = c.id, claimed_at = now() where code = k.code;
  update promo_claims set status = 'redeemed', platform = p_platform where id = c.id;
  return jsonb_build_object('code', k.code, 'platform', k.platform, 'app', c.app, 'already', false);
end $$;

-- 等著寄信的申請（status = 'approved'）。給 p_ids 就只找那幾筆。
create or replace function public.promo_approved(p_ids uuid[] default null, p_limit int default 50)
returns table (id uuid, email text, app text)
language sql stable set search_path = public as $$
  select c.id, c.email, c.app from promo_claims c
  where c.status = 'approved' and (p_ids is null or c.id = any (p_ids))
  order by c.created_at limit p_limit
$$;

-- 寄信前：把 approved 的申請標成 sent 並存 token 雜湊。只有 approved 的會成功（回傳 Email 和 App）。
create or replace function public.promo_mark_sent(p_claim_id uuid, p_token_hash text, p_days int default 30) returns jsonb
language sql set search_path = public as $$
  update promo_claims set status = 'sent', token_hash = p_token_hash, token_expires_at = now() + make_interval(days => p_days), sent_at = now()
  where id = p_claim_id and status = 'approved'
  returning jsonb_build_object('email', email, 'app', app)
$$;

-- 寄信失敗：退回 approved，下次再寄。
create or replace function public.promo_unsend(p_claim_id uuid) returns void
language sql set search_path = public as $$
  update promo_claims set status = 'approved', token_hash = null, token_expires_at = null, sent_at = null
  where id = p_claim_id and status = 'sent'
$$;

-- 活動結束 90 天後刪除個資（Email、貼文連結、截圖路徑）。截圖檔案本身要在 Storage 另外刪（promo-send 的 cleanup 會做）。
create or replace function public.promo_cleanup() returns setof text
language plpgsql set search_path = public as $$
declare done text;
begin
  for done in
    select c.id from promo_campaigns c where c.ends_at is not null and c.ends_at < now() - interval '90 days'
  loop
    return query select proof_image_path from promo_claims where campaign = done and proof_image_path is not null;
    delete from promo_claims where campaign = done;   -- promo_codes.claimed_by 會變成 null，代碼本身保留
  end loop;
  delete from promo_hits;
end $$;

revoke all on function public.promo_current(), public.promo_stats(), public.promo_rate_hit(text, text, int),
  public.promo_apply(text, text, text, int, int, text, text, text), public.promo_claim_lookup(text),
  public.promo_issue_code(uuid, text), public.promo_approved(uuid[], int), public.promo_mark_sent(uuid, text, int), public.promo_unsend(uuid), public.promo_cleanup()
  from public, anon, authenticated;
grant execute on function public.promo_current(), public.promo_stats(), public.promo_rate_hit(text, text, int),
  public.promo_apply(text, text, text, int, int, text, text, text), public.promo_claim_lookup(text),
  public.promo_issue_code(uuid, text), public.promo_approved(uuid[], int), public.promo_mark_sent(uuid, text, int), public.promo_unsend(uuid), public.promo_cleanup()
  to service_role;

-- 活動開始時新增一筆（期間和名額決定後再填）：
-- insert into public.promo_campaigns (id, quota, starts_at, ends_at) values ('social_2026', 200, '2026-12-20 00:00+08', '2027-01-31 23:59+08');

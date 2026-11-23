-- JuanGo 測試版一次性下載連結（表名沿用 dev_ 開頭）：安裝檔放在私人儲存空間 dev-builds，外人拿不到。
-- 新同學用一次性連結下載（dev-download 函式換成 10 分鐘有效的網址，用過就失效）；
-- 已經在內測名單 dev_testers 裡的帳號，App 會用 dev_latest() 查新版，自己簽下載網址。
--
-- 發一個一次性連結：  select public.dev_link_new('同學名字');
-- 把帳號加進內測名單：insert into public.dev_testers (user_id, note) values ('<uuid>', '同學名字');

insert into storage.buckets (id, name, public, file_size_limit)
values ('dev-builds', 'dev-builds', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

create table if not exists public.dev_testers (
  user_id  uuid primary key references auth.users on delete cascade,
  note     text,
  added_at timestamptz not null default now()
);

create table if not exists public.dev_builds (
  build      int primary key,
  version    text not null,
  notes      text not null default '',
  path       text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.dev_links (
  token      text primary key default encode(extensions.gen_random_bytes(12), 'hex'),
  note       text,
  created_at timestamptz not null default now(),
  used_at    timestamptz,
  used_build int
);

alter table public.dev_testers enable row level security;
alter table public.dev_builds enable row level security;
alter table public.dev_links enable row level security;

-- the newest build, only for accounts on the tester list
create or replace function public.dev_latest() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from dev_testers t where t.user_id = auth.uid()) then
    (select jsonb_build_object('build', b.build, 'version', b.version, 'notes', b.notes, 'path', b.path)
       from dev_builds b order by b.build desc limit 1)
  end
$$;
revoke execute on function public.dev_latest() from public, anon;
grant execute on function public.dev_latest() to authenticated;

-- spends a one-time link; only the dev-download edge function (service role) may call it
create or replace function public.dev_link_use(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b dev_builds;
begin
  select * into b from dev_builds order by build desc limit 1;
  if b.build is null then return null; end if;
  update dev_links set used_at = now(), used_build = b.build where token = p_token and used_at is null;
  if not found then return null; end if;
  return jsonb_build_object('build', b.build, 'version', b.version, 'path', b.path);
end $$;
revoke execute on function public.dev_link_use(text) from public, anon, authenticated;
grant execute on function public.dev_link_use(text) to service_role;

create or replace function public.dev_link_new(p_note text) returns text
language sql security definer set search_path = public as $$
  insert into dev_links (note) values (p_note) returning 'https://howweichi-app.github.io/juango/download/?t=' || token
$$;
revoke execute on function public.dev_link_new(text) from public, anon, authenticated;

-- testers may sign download URLs for the builds (dev_testers has no read policy, so check it as definer)
create or replace function public.is_dev_tester() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dev_testers t where t.user_id = auth.uid())
$$;
grant execute on function public.is_dev_tester() to authenticated;
drop policy if exists "dev testers read builds" on storage.objects;
create policy "dev testers read builds" on storage.objects for select to authenticated
  using (bucket_id = 'dev-builds' and public.is_dev_tester());

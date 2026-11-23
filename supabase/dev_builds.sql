-- 開發帳號名單和舊的 Android 開發版更新：安裝檔放在私人儲存空間 dev-builds，外人拿不到。
-- dev_testers 裡的帳號登入後 App 會打開開發帳號（my_account() 的 tester，見 account.sql）。
-- 舊的開發版 App（1.0.0）用 dev_latest() 查新版、自己簽下載網址；新版 App 改讀 GitHub 上的 release/latest.json。
-- 一次性下載連結（dev_links）已在 2026-11-23 移除，見 admin.sql。
--
-- 把帳號加進開發帳號名單：insert into public.dev_testers (user_id, note) values ('<uuid>', '同學名字');

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


alter table public.dev_testers enable row level security;
alter table public.dev_builds enable row level security;

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

-- testers may sign download URLs for the builds (dev_testers has no read policy, so check it as definer)
create or replace function public.is_dev_tester() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dev_testers t where t.user_id = auth.uid())
$$;
grant execute on function public.is_dev_tester() to authenticated;
drop policy if exists "dev testers read builds" on storage.objects;
create policy "dev testers read builds" on storage.objects for select to authenticated
  using (bucket_id = 'dev-builds' and public.is_dev_tester());

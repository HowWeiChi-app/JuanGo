-- JuanGo 開發版「回報問題」：開發者選項裡送出的說明和 log。
-- Log 平常只存在手機，只有使用者按「送出」時才會上傳到這裡。
-- Run once in Supabase → SQL Editor → New query → Run. Safe to run again.
--
-- 看最新的回報：select created_at, platform, version, build, device, message, length(log) from public.dev_reports order by created_at desc limit 20;
-- 看某一筆的完整 log：select log from public.dev_reports where id = '<id>';

create table if not exists public.dev_reports (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade default auth.uid(),
  app        text not null default 'juango' check (app in ('juango', 'bango')),
  platform   text not null check (platform in ('ios', 'android')),
  version    text not null default '',
  build      text not null default '',
  device     text not null default '' check (char_length(device) <= 200),
  message    text not null check (char_length(message) between 1 and 4000),
  log        text not null default '' check (char_length(log) <= 250000),
  created_at timestamptz not null default now()
);
create index if not exists dev_reports_created on public.dev_reports (created_at desc);

alter table public.dev_reports enable row level security;

-- a signed-in tester can only add reports as themselves; nobody can read them from the app
-- (you read them here in the dashboard)
drop policy if exists "send own report" on public.dev_reports;
create policy "send own report" on public.dev_reports for insert to authenticated
  with check (user_id = auth.uid());

-- at most 20 reports per account per day, so a stuck button can't flood the table
create or replace function public.dev_reports_limit() returns trigger
language plpgsql volatile security definer set search_path = public as $$
begin
  if (select count(*) from dev_reports where user_id = new.user_id and created_at > now() - interval '1 day') >= 20 then
    raise exception 'dev_reports_limit: 20 reports a day' using errcode = 'P0001';
  end if;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists dev_reports_limit on public.dev_reports;
create trigger dev_reports_limit before insert on public.dev_reports
  for each row execute function public.dev_reports_limit();

grant insert on public.dev_reports to authenticated;

-- reports older than 180 days are removed once a day
create or replace function public.dev_reports_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from public.dev_reports where created_at < now() - interval '180 days'
$$;
revoke all on function public.dev_reports_cleanup() from public, anon, authenticated;
create extension if not exists pg_cron;
select cron.schedule('dev-reports-cleanup', '23 4 * * *', 'select public.dev_reports_cleanup()');

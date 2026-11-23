-- 6. 回報單字問題（單字頁 › 更多 › 回報問題）。Run once in Supabase → SQL Editor.
-- Anyone can report, signed in or not; nobody can read reports back through the API (the developer
-- handles them in the Dashboard). Reports only go in through report_word(), which drops repeats.
create table if not exists public.word_reports (
  id          bigserial primary key,
  user_id     uuid references auth.users on delete set null,   -- null when not signed in
  device      text check (char_length(device) <= 64),            -- the app's install id, for people not signed in
  client_id   uuid unique,                                       -- made by the app, so a report resent after being offline counts once
  word        text check (char_length(word) <= 80),              -- null for an exam question
  exam_ref    text check (char_length(exam_ref) <= 20),          -- e.g. '115-12' (學年度-題號)
  kind        text not null check (kind in ('meaning','ipa','pos','example','example_zh','audio','similar','level','exam','other')),
  note        text check (char_length(note) <= 200),
  snapshot    jsonb not null check (pg_column_size(snapshot) < 8000),  -- the meaning, example and IPA shown at the time
  app_version text check (char_length(app_version) <= 20),
  platform    text check (platform in ('ios','android')),
  status      text not null default 'pending' check (status in ('pending','fixed','wontfix')),
  created_at  timestamptz not null default now()
);
create index if not exists word_reports_status on public.word_reports (status, created_at);
alter table public.word_reports enable row level security;   -- no policies: only report_word() writes

-- Returns 'ok', 'duplicate' (the same person already reported this word for this reason today,
-- or this client_id already arrived) or 'limited' (30 a day per device/account, 200 an hour from
-- everyone not signed in) — all mean the app can drop it from its queue.
-- Same function as supabase/abuse_limits.sql: keep the two in step so re-running this file keeps the limits.
create index if not exists word_reports_device_day on public.word_reports (device, created_at);
create index if not exists word_reports_user_day on public.word_reports (user_id, created_at);
create index if not exists word_reports_created on public.word_reports (created_at);
create or replace function public.report_word(
  p_client_id uuid, p_word text, p_exam_ref text, p_kind text, p_note text, p_snapshot jsonb,
  p_app_version text, p_platform text, p_device text
) returns text
language plpgsql security definer set search_path = public as $$
declare
  who uuid := auth.uid();
  today timestamptz := date_trunc('day', now() at time zone 'Asia/Taipei') at time zone 'Asia/Taipei';
begin
  if p_word is null and p_exam_ref is null then raise exception '沒有要回報的單字或題目'; end if;
  if exists (select 1 from word_reports where client_id = p_client_id) then return 'duplicate'; end if;
  if exists (
    select 1 from word_reports r
    where r.kind = p_kind
      and r.word is not distinct from lower(p_word) and r.exam_ref is not distinct from p_exam_ref
      and r.created_at >= today
      and (case when who is not null then r.user_id = who else r.user_id is null and r.device = p_device end)
  ) then return 'duplicate'; end if;
  if (select count(*) from word_reports r
      where r.created_at >= today
        and ((who is not null and r.user_id = who) or (p_device is not null and r.device = p_device))) >= 30
  then return 'limited'; end if;
  if who is null and (select count(*) from word_reports r
                      where r.user_id is null and r.created_at >= now() - interval '1 hour') >= 200
  then return 'limited'; end if;
  insert into word_reports (user_id, device, client_id, word, exam_ref, kind, note, snapshot, app_version, platform)
  values (who, p_device, p_client_id, lower(p_word), p_exam_ref, p_kind, nullif(trim(p_note), ''),
          coalesce(p_snapshot, '{}'::jsonb), p_app_version, p_platform);
  return 'ok';
end $$;
revoke all on function public.report_word(uuid, text, text, text, text, jsonb, text, text, text) from public;
grant execute on function public.report_word(uuid, text, text, text, text, jsonb, text, text, text) to anon, authenticated;

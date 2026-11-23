-- 雲端 AI（Agnes）每月配額。和 supabase/functions/ai 一起用；在 subscriptions.sql 之後執行，可以重複執行。
-- 只有 Pro（has_pro）能用；每個帳號每個月（台灣時間）最多 p_limit 次，Edge Function 用 service role 呼叫。

create table if not exists public.ai_usage (
  user_id  uuid not null references auth.users on delete cascade,
  month    text not null,              -- 'YYYY-MM'（Asia/Taipei）
  calls    int not null default 0,
  primary key (user_id, month)
);
alter table public.ai_usage enable row level security;
drop policy if exists "read own ai usage" on public.ai_usage;
create policy "read own ai usage" on public.ai_usage for select using (auth.uid() = user_id);
grant select on public.ai_usage to authenticated;

-- 扣一次：'ok'、'not_pro'（沒有 Pro）、'quota'（這個月用完了）
create or replace function public.ai_take(p_user uuid, p_limit int) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_month text := to_char(now() at time zone 'Asia/Taipei', 'YYYY-MM');
  v_calls int;
begin
  if not has_pro(p_user) then return 'not_pro'; end if;
  insert into ai_usage (user_id, month, calls) values (p_user, v_month, 1)
  on conflict (user_id, month) do update set calls = ai_usage.calls + 1
    where ai_usage.calls < p_limit
  returning calls into v_calls;
  return case when v_calls is null then 'quota' else 'ok' end;
end $$;

-- App 顯示「這個月還剩幾次」
create or replace function public.ai_left(p_limit int default 300) returns int
language sql stable security definer set search_path = public as $$
  select greatest(0, p_limit - coalesce((select calls from ai_usage
    where user_id = auth.uid() and month = to_char(now() at time zone 'Asia/Taipei', 'YYYY-MM')), 0))
$$;

revoke all on function public.ai_take(uuid, int) from public, anon, authenticated;
grant execute on function public.ai_left(int) to authenticated;

-- 帳號資訊：App 登入後（和每次打開時）呼叫一次 my_account()，拿到
--   id       使用者 ID（10 碼，就是對戰的 pid，也是好友代碼），設定頁顯示
--   tester   在 dev_testers 名單裡 → App 打開開發帳號（GOs PRO、開發者選項、回報問題）
--   placed_level  做過 18 題程度測驗的程度；換手機或重裝後 App 用它跳過重測
--   plan / expires_at  捲字 Pro、GOs PRO（訂閱、衝刺包、兌換碼和 promo 的 entitlements）
-- 第一次呼叫會建立對戰玩家資料（battle_player），所以每個登入過的人都有 ID。
-- 在 SQL Editor 執行整個檔案；重跑沒關係。

create or replace function public.my_account() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p public.battle_players := battle_player(null);
  v_gos timestamptz := gos_pro_expires_at(p.user_id);
  v_juango timestamptz := juango_pro_expires_at(p.user_id);
begin
  return jsonb_build_object(
    'id', upper(p.pid),
    'tester', exists (select 1 from dev_testers t where t.user_id = p.user_id),
    'placed_level', p.placed_level,
    'plan', case when v_gos is not null then 'gos' when v_juango is not null then 'juango' end,
    'expires_at', greatest(v_gos, v_juango));
end $$;

revoke all on function public.my_account() from public, anon;
grant execute on function public.my_account() to authenticated;

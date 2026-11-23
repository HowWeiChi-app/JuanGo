-- 對戰函式的 App 執行權限（可以隨時重跑）
-- battle.sql／battle_ranked.sql 會先把所有 battle_* 函式的權限收回，只還給自己檔案裡的函式；
-- 在 battle_social.sql、battle_lobby.sql 之後重跑它們，好友列表、房間等候室、邀請等就會出現
-- 「permission denied for function battle_friend_list」。這個檔把 App 會呼叫的函式全部還給登入使用者。
-- 照名稱找函式（不管參數型別），還沒建立的函式自動跳過；內部用的函式不在清單裡，維持收回。
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array[
             -- battle.sql／battle_ranked.sql
             'battle_me', 'battle_set_name', 'battle_find', 'battle_cancel_find', 'battle_create_room', 'battle_join',
             'battle_rematch', 'battle_state', 'battle_answer', 'battle_quit', 'battle_board', 'battle_report',
             'battle_block', 'battle_blocked', 'battle_unblock', 'battle_set_hidden', 'battle_dev_limit', 'battle_retest_done',
             -- battle_social.sql
             'battle_room_add_bot', 'battle_room_set_public', 'battle_public_rooms', 'battle_join_public',
             'battle_add_friend', 'battle_remove_friend', 'battle_friend_list', 'battle_tier_detail',
             -- battle_lobby.sql
             'battle_room_state', 'battle_room_ready', 'battle_room_start', 'battle_room_kick',
             'battle_room_invite', 'battle_my_invites', 'battle_invite_dismiss', 'battle_room_invited'])
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- 檢查：每一列的 authenticated 都應該是 true
select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as authenticated
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('battle_friend_list', 'battle_add_friend', 'battle_remove_friend',
  'battle_public_rooms', 'battle_my_invites', 'battle_room_invite', 'battle_tier_detail')
order by 1;

-- 檢查：排行有沒有含電腦（false 代表 battle_ranked.sql 被重跑過，要再跑 battle_social.sql → battle_lobby.sql → subscriptions.sql → 這個檔）
select pg_get_functiondef('public.battle_board_season(text, int, uuid)'::regprocedure) like '%battle_season_pool%' as leaderboard_has_bots;

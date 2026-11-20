# 社群活動的 Edge Function

官網「發一篇文，免費用一年」（`free-year/`、`redeem/`）的後端。跟捲字同一個 Supabase 專案。

| 函式 | 誰呼叫 | 做什麼 |
| --- | --- | --- |
| `promo-stats` | 官網活動頁 | 剩餘名額、活動有沒有開放 |
| `promo-apply` | 官網活動頁 | 截圖的上傳網址；送出申請（重新檢查所有欄位、Turnstile、同一個 IP 每小時 5 次、同 Email 或同一篇貼文只能一次） |
| `promo-claim` | 官網兌換頁 | 用 Email 裡的 token 拿一組 App Store／Google Play 兌換碼，一個 token 只有一組 |
| `promo-send` | 開發者自己 | 寄啟用信給審核通過的申請；活動結束 90 天後清資料 |

邏輯在各資料夾的 `handler.ts`，`index.ts` 只是進入點。檢查規則在 `_shared/rules.ts`，跟官網的 `site/js/promo-api.js` 一樣。

## 測試

```bash
node --test supabase/functions/test/
```

資料庫用記憶體裡的假資料，行為照 `supabase/promo.sql`。SQL 本身要在 Supabase 上跑過才算測過。

## 第一次設定

1. Supabase › SQL Editor 執行 `supabase/promo.sql`（建表、私人 bucket `promo-proofs`、函式）。
2. 決定期間和名額後新增活動：`insert into promo_campaigns (id, quota, starts_at, ends_at) values ('social_2026', 200, …, …);`
3. 匯入兌換碼到 `promo_codes`（`code`、`platform` 是 ios 或 android、`app` 是 juango 或 bango）。
4. 設定 secrets（Dashboard › Edge Functions › Secrets）：

   | 名稱 | 內容 |
   | --- | --- |
   | `TURNSTILE_SECRET_KEY` | Cloudflare Turnstile 的 secret key（site key 填在官網 `pages.py` 的 `BACKEND`） |
   | `PROMO_IP_SALT` | 任意長字串，IP 只存加鹽後的雜湊 |
   | `PROMO_ADMIN_SECRET` | 至少 24 個字元，呼叫 `promo-send` 時放在 `x-admin-secret` header |
   | `RESEND_API_KEY` | Resend 的 API key |
   | `PROMO_FROM_EMAIL` | 寄件人，例如 `HowWeiChi <no-reply@你驗證過的網域>` |

   `SUPABASE_URL` 和 `SUPABASE_SERVICE_ROLE_KEY` 是 Supabase 自動提供的，不用設。
5. 部署（要先安裝 Supabase CLI 並 `supabase link`）。官網呼叫的三個不檢查 JWT：

   ```bash
   supabase functions deploy promo-stats --no-verify-jwt
   supabase functions deploy promo-apply --no-verify-jwt
   supabase functions deploy promo-claim --no-verify-jwt
   supabase functions deploy promo-send
   ```

6. 官網 `pages.py` 的 `BACKEND` 填 `functions_url`（`https://<project>.supabase.co/functions/v1`）、`anon_key`、`turnstile_site_key`、兩個 App 的 Apple ID，重新 build。填了以後官網就不是預覽模式。

## 審核和寄信

1. Dashboard › Table Editor › `promo_claims`，打開貼文連結確認，把 `status` 改成 `approved` 或 `rejected`。
2. 寄信（先用 `dry_run` 看會寄給誰）：

   ```bash
   curl -X POST https://<project>.supabase.co/functions/v1/promo-send \
     -H "Authorization: Bearer <service role key>" -H "x-admin-secret: <PROMO_ADMIN_SECRET>" \
     -H "Content-Type: application/json" -d '{"action":"send","dry_run":true}'
   ```

   拿掉 `dry_run` 就會真的寄。寄失敗的會退回 `approved`，下次再寄。
3. 活動結束 90 天後：`-d '{"action":"cleanup"}'` 刪除申請資料和截圖。

## 上線前要確認

- Email 最後一句續訂說明（`promo-send/handler.ts` 的 `RENEW_LINE`）要跟商店兌換碼的實際設定一致。
- 兌換網址格式（官網 `js/redeem.js` 的 `storeUrl`）用 Apple 和 Google 的文件再確認一次。

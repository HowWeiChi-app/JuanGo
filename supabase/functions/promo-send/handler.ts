// POST promo-send：開發者自己呼叫（不是給官網用的）。Header 要帶 x-admin-secret: <PROMO_ADMIN_SECRET>。
//   { action: 'send', claim_ids?: string[], limit?: number, dry_run?: boolean }
//     把 status = 'approved' 的申請產生一次性 token、寄啟用信（Gmail，跟登入連結同一個寄信帳號）、改成 'sent'。寄信失敗會退回 'approved'。
//     回傳 { sent: [id], failed: [{ id, error }], skipped: [id] }，不會回傳 token。
//   { action: 'cleanup' }：活動結束 90 天後刪除申請資料和截圖檔案。
import { body, type Env, newToken, sha256 } from "../_shared/http.ts";
import type { Db } from "../_shared/db.ts";
import type { Mail } from "../_shared/mail-type.ts";

const SITE = "https://howweichi-app.github.io";
const APP_NAME: Record<string, string> = { juango: "捲字 JuanGo", bango: "校板 BanGo" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const out = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Email 範本（website-next.md 3.4）。最後一句續訂的說明要跟商店兌換碼的實際設定一致，上線前確認後改 RENEW_LINE。
export const RENEW_LINE = "免費期間結束後會不會續訂，以商店兌換畫面顯示的為準；不想續訂的話，到期前在 App Store 或 Google Play 取消就好。";
export function email(app: string, url: string) {
  const name = APP_NAME[app] ?? "HowWeiChi";
  const text = `謝謝你幫我們介紹給同學！
點下面的連結就能啟用一年免費的${name} Pro：

${url}

連結 30 天內有效，只能用一次。
兌換前先在 App 裡登入，換手機也不會不見。
${RENEW_LINE}

HowWeiChi`;
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const html = `<div style="font:16px/1.6 -apple-system,'PingFang TC',sans-serif;color:#262421">
<p>謝謝你幫我們介紹給同學！<br>點下面的按鈕就能啟用一年免費的${esc(name)} Pro：</p>
<p><a href="${esc(url)}" style="display:inline-block;padding:12px 22px;border-radius:999px;background:#960e25;color:#fff;text-decoration:none">啟用免費一年</a></p>
<p style="font-size:14px;color:#5f5a50">按鈕打不開的話，複製這個網址：<br>${esc(url)}</p>
<p>連結 30 天內有效，只能用一次。<br>兌換前先在 App 裡登入，換手機也不會不見。<br>${esc(RENEW_LINE)}</p>
<p>HowWeiChi</p></div>`;
  return { subject: `你的${name} Pro 免費一年`, text, html };
}

export async function handle(req: Request, db: Db, env: Env, mail: Mail | null): Promise<Response> {
  const secret = env("PROMO_ADMIN_SECRET");
  if (!secret || secret.length < 24 || !same(req.headers.get("x-admin-secret") ?? "", secret)) return out({ error: "forbidden" }, 403);
  if (req.method !== "POST") return out({ error: "method" }, 405);
  const b = (await body(req)) ?? {};

  if (b.action === "cleanup") {
    const r = await db.rpc("promo_cleanup");
    if (r.error) return out({ error: r.error.message }, 500);
    const paths = ((r.data as string[] | null) ?? []).filter(Boolean);
    await db.removeFiles(paths);
    return out({ removed_files: paths.length });
  }
  if (b.action !== "send") return out({ error: "action 要是 send 或 cleanup" }, 400);

  const ids = Array.isArray(b.claim_ids) ? b.claim_ids.filter((x): x is string => typeof x === "string" && UUID.test(x)) : null;
  const limit = Number.isInteger(b.limit) ? Math.min(Math.max(b.limit as number, 1), 200) : 50;
  const list = await db.rpc("promo_approved", { p_ids: ids, p_limit: limit });
  if (list.error) return out({ error: list.error.message }, 500);
  const claims = (list.data as { id: string; email: string; app: string }[] | null) ?? [];
  if (b.dry_run === true) return out({ would_send: claims.map((c) => ({ id: c.id, app: c.app })) });

  if (!mail) return out({ error: "缺少 GMAIL_USER 或 GMAIL_APP_PASSWORD" }, 500);
  const sent: string[] = [], skipped: string[] = [], failed: { id: string; error: string }[] = [];
  for (const c of claims) {
    const token = newToken();
    const mark = await db.rpc("promo_mark_sent", { p_claim_id: c.id, p_token_hash: await sha256(token) });
    if (mark.error || !mark.data) { skipped.push(c.id); continue; }   // 已經不是 approved（例如同時跑了兩次）
    const m = email(c.app, `${SITE}/redeem/?t=${token}`);
    let ok = false, why = "";
    try { await mail({ to: c.email, ...m }); ok = true; } catch (e) { why = String(e instanceof Error ? e.message : e); }
    if (ok) sent.push(c.id);
    else { failed.push({ id: c.id, error: why }); await db.rpc("promo_unsend", { p_claim_id: c.id }); }
  }
  return out({ sent, failed, skipped });
}

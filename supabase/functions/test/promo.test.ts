// 用 node 測活動的 Edge Function 邏輯：node --test supabase/functions/test/
// 資料庫換成記憶體裡的假資料庫，行為照 supabase/promo.sql 的函式。SQL 本身要在 Supabase 上測。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePost, checkApplication } from "../_shared/rules.ts";
import { sha256 } from "../_shared/http.ts";
import { handle as stats } from "../promo-stats/handler.ts";
import { handle as apply } from "../promo-apply/handler.ts";
import { handle as claim } from "../promo-claim/handler.ts";
import { handle as send, email } from "../promo-send/handler.ts";
import type { Db } from "../_shared/db.ts";

type Claim = { id: string; email: string; post_url: string; app: string; status: string; token_hash?: string; expires?: number; platform?: string };
function fakeDb(quota = 3) {
  const s = { quota, open: true, claims: [] as Claim[], codes: [] as { code: string; app: string; platform: string; by?: string }[], hits: [] as string[], uploads: [] as string[] };
  const used = () => s.claims.filter((c) => c.status !== "rejected").length;
  const db: Db = {
    async rpc(fn, a: any = {}) {
      const ok = (data: unknown) => ({ data, error: null });
      switch (fn) {
        case "promo_stats": return ok({ open: s.open, remaining: Math.max(0, s.quota - used()) });
        case "promo_rate_hit": {
          const n = s.hits.filter((h) => h === a.p_ip_hash + a.p_kind).length;
          if (n >= a.p_limit) return ok(false);
          s.hits.push(a.p_ip_hash + a.p_kind); return ok(true);
        }
        case "promo_apply":
          if (!s.open) return ok("closed");
          if (s.claims.some((c) => c.email === a.p_email.toLowerCase() || c.post_url === a.p_post_url)) return ok("duplicate");
          if (used() >= s.quota) return ok("closed");
          s.claims.push({ id: crypto.randomUUID(), email: a.p_email.toLowerCase(), post_url: a.p_post_url, app: a.p_app, status: "pending" });
          return ok("ok");
        case "promo_claim_lookup": {
          const c = s.claims.find((x) => x.token_hash === a.p_token_hash && ["sent", "redeemed"].includes(x.status));
          if (!c) return ok(null);
          const k = s.codes.find((x) => x.by === c.id);
          return ok({ id: c.id, app: c.app, status: c.status, expired: (c.expires ?? 0) < Date.now(), code: k?.code ?? null, platform: k?.platform ?? null });
        }
        case "promo_issue_code": {
          const c = s.claims.find((x) => x.id === a.p_claim_id)!;
          const mine = s.codes.find((x) => x.by === c.id);
          if (mine) return ok({ code: mine.code, platform: mine.platform, app: c.app, already: true });
          if (c.status !== "sent" || (c.expires ?? 0) < Date.now()) return ok(null);
          const k = s.codes.find((x) => !x.by && x.app === c.app && x.platform === a.p_platform);
          if (!k) return ok({ sold_out: true });
          k.by = c.id; c.status = "redeemed"; c.platform = a.p_platform;
          return ok({ code: k.code, platform: k.platform, app: c.app, already: false });
        }
        case "promo_approved": return ok(s.claims.filter((c) => c.status === "approved").map(({ id, email, app }) => ({ id, email, app })));
        case "promo_mark_sent": {
          const c = s.claims.find((x) => x.id === a.p_claim_id && x.status === "approved");
          if (!c) return ok(null);
          c.status = "sent"; c.token_hash = a.p_token_hash; c.expires = Date.now() + 30 * 864e5;
          return ok({ email: c.email, app: c.app });
        }
        case "promo_unsend": { const c = s.claims.find((x) => x.id === a.p_claim_id)!; c.status = "approved"; delete c.token_hash; return ok(null); }
        case "promo_cleanup": return ok([]);
      }
      throw new Error("unknown rpc " + fn);
    },
    signedUpload: async (path) => { s.uploads.push(path); return { url: "https://example.test/upload/" + path }; },
    removeFiles: async () => {},
  };
  return { s, db };
}

const env = (extra: Record<string, string> = {}) => (k: string) => ({ PROMO_SKIP_TURNSTILE: "1", PROMO_IP_SALT: "salt", ...extra })[k];
const post = (fn: string, b: unknown, ip = "1.2.3.4", headers: Record<string, string> = {}) =>
  new Request(`https://x.test/${fn}`, { method: "POST", headers: { "content-type": "application/json", "x-forwarded-for": ip, origin: "https://howweichi-app.github.io", ...headers }, body: JSON.stringify(b) });
const good = { step: "submit", email: "Student@Example.com", post_url: "instagram.com/p/DAbcdEFgh12/?igsh=x", platform: "instagram", likes: 20, views: 12000, app: "juango", device: "ios", agreed: true };

test("連結規則：限動、一般貼文、Threads", () => {
  assert.match((parsePost("https://www.instagram.com/stories/a/123456/") as any).error, /限動/);
  assert.deepEqual(parsePost("instagram.com/reel/AbCdE12/"), { url: "https://www.instagram.com/reel/AbCdE12/", platform: "instagram" });
  assert.deepEqual(parsePost("https://www.instagram.com/some.user/p/AbCdE12"), { url: "https://www.instagram.com/p/AbCdE12/", platform: "instagram" });
  assert.equal((parsePost("https://threads.net/@a.b/post/C1a2b3") as any).platform, "threads");
  assert.ok("error" in parsePost("https://www.instagram.com/someone/"));
  assert.ok("error" in parsePost("https://evil.com/p/AbCdE12"));
});

test("申請：門檻、勾選、數字都要再檢查", () => {
  assert.equal((checkApplication({ ...good, likes: 99, views: 9999 }) as any).field, "views");
  assert.equal((checkApplication({ ...good, agreed: "true" }) as any).field, "agree");
  assert.equal((checkApplication({ ...good, likes: "500" }) as any).field, "likes");
  assert.equal((checkApplication({ ...good, proof_path: "../../etc/passwd" }) as any).field, "proof");
  assert.equal((checkApplication(good) as any).email, "student@example.com");
});

test("promo-apply：成功、重複 Email、重複貼文、限動、沒達門檻", async () => {
  const { s, db } = fakeDb();
  let r = await apply(post("promo-apply", good), db, env());
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("access-control-allow-origin"), "https://howweichi-app.github.io");
  r = await apply(post("promo-apply", { ...good, post_url: "https://www.instagram.com/p/Other123/" }, "5.5.5.5"), db, env());
  assert.equal(r.status, 409);
  r = await apply(post("promo-apply", { ...good, email: "b@example.com" }, "5.5.5.6"), db, env());
  assert.equal((await r.json()).error, "duplicate");
  r = await apply(post("promo-apply", { ...good, email: "c@example.com", post_url: "https://instagram.com/stories/x/123456/" }), db, env());
  assert.equal((await r.json()).field, "post");
  r = await apply(post("promo-apply", { ...good, email: "d@example.com", post_url: "https://instagram.com/p/Third12/", likes: 1, views: 1 }), db, env());
  assert.equal((await r.json()).field, "views");
  assert.equal(s.claims.length, 1);
});

test("promo-apply：同一個 IP 每小時 5 次、Turnstile、名額滿了", async () => {
  const { db, s } = fakeDb(100);
  for (let i = 0; i < 5; i++) await apply(post("promo-apply", { ...good, email: `u${i}@example.com`, post_url: `https://instagram.com/p/Post${i}xx/` }, "9.9.9.9"), db, env());
  let r = await apply(post("promo-apply", { ...good, email: "u9@example.com", post_url: "https://instagram.com/p/Post9xx/" }, "9.9.9.9"), db, env());
  assert.equal(r.status, 429);
  r = await apply(post("promo-apply", { ...good, email: "t@example.com", turnstile: "x" }, "8.8.8.8"), db, env({ PROMO_SKIP_TURNSTILE: "", TURNSTILE_SECRET_KEY: "k" }),
    (async () => new Response(JSON.stringify({ success: false }))) as typeof fetch);
  assert.equal((await r.json()).error, "bot");
  s.quota = s.claims.length;
  r = await apply(post("promo-apply", { ...good, email: "z@example.com", post_url: "https://instagram.com/p/Zzzzz1/" }, "7.7.7.7"), db, env());
  assert.equal((await r.json()).error, "closed");
  const st = await (await stats(new Request("https://x.test/promo-stats"), db)).json();
  assert.deepEqual(st, { remaining: 0, open: false });
});

test("promo-apply：截圖只收圖片、5MB 以內，路徑由伺服器決定", async () => {
  const { db } = fakeDb();
  let r = await apply(post("promo-apply", { step: "proof", type: "image/png", size: 1000 }), db, env());
  const d = await r.json();
  assert.match(d.path, /^\d{6}\/[0-9a-f-]{36}\.png$/);
  assert.equal((checkApplication({ ...good, proof_path: d.path }) as any).proof_path, d.path);
  r = await apply(post("promo-apply", { step: "proof", type: "application/pdf", size: 1000 }), db, env());
  assert.equal(r.status, 400);
  r = await apply(post("promo-apply", { step: "proof", type: "image/jpeg", size: 6e6 }), db, env());
  assert.equal(r.status, 400);
});

test("promo-send → promo-claim：一個 token 一組代碼，再打開是同一組", async () => {
  const { s, db } = fakeDb();
  await apply(post("promo-apply", good), db, env());
  s.claims[0].status = "approved";
  s.codes.push({ code: "IOS-1", app: "juango", platform: "ios" }, { code: "IOS-2", app: "juango", platform: "ios" });
  const mails: any[] = [];
  const fakeResend = (async (_u: string, init: any) => { mails.push(JSON.parse(init.body)); return new Response("{}", { status: 200 }); }) as typeof fetch;
  const admin = { "x-admin-secret": "a-very-long-admin-secret-123" };
  let r = await send(post("promo-send", { action: "send" }, "1.1.1.1", { "x-admin-secret": "wrong" }), db, env({ PROMO_ADMIN_SECRET: "a-very-long-admin-secret-123" }), fakeResend);
  assert.equal(r.status, 403);
  r = await send(post("promo-send", { action: "send" }, "1.1.1.1", admin), db, env({ PROMO_ADMIN_SECRET: "a-very-long-admin-secret-123", RESEND_API_KEY: "re", PROMO_FROM_EMAIL: "HowWeiChi <a@b.c>" }), fakeResend);
  assert.deepEqual((await r.json()).sent, [s.claims[0].id]);
  assert.equal(mails[0].to[0], "student@example.com");
  const token = mails[0].text.match(/redeem\/\?t=([\w-]+)/)[1];
  assert.equal(s.claims[0].token_hash, await sha256(token));
  assert.ok(!JSON.stringify(s.claims).includes(token), "token 本身不存");

  let c = await (await claim(post("promo-claim", { token, peek: true }), db, env())).json();
  assert.deepEqual(c, { status: "fresh", app: "juango" });
  c = await (await claim(post("promo-claim", { token, platform: "ios" }), db, env())).json();
  assert.equal(c.code, "IOS-1"); assert.equal(c.already, false);
  c = await (await claim(post("promo-claim", { token, platform: "android" }), db, env())).json();
  assert.equal(c.code, "IOS-1"); assert.equal(c.already, true);
  assert.equal(s.codes[1].by, undefined);
  const bad = await claim(post("promo-claim", { token: "x".repeat(43) }), db, env());
  assert.equal(bad.status, 404);
});

test("promo-claim：過期、代碼發完；寄信失敗會退回 approved", async () => {
  const { s, db } = fakeDb();
  s.claims.push({ id: crypto.randomUUID(), email: "a@x.co", post_url: "u1", app: "bango", status: "sent", token_hash: await sha256("t".repeat(43)), expires: Date.now() - 1 });
  s.claims.push({ id: crypto.randomUUID(), email: "b@x.co", post_url: "u2", app: "bango", status: "sent", token_hash: await sha256("s".repeat(43)), expires: Date.now() + 1e6 });
  assert.equal((await (await claim(post("promo-claim", { token: "t".repeat(43), platform: "ios" }), db, env())).json()).error, "expired");
  assert.equal((await (await claim(post("promo-claim", { token: "s".repeat(43), platform: "ios" }), db, env())).json()).error, "sold_out");
  s.claims.push({ id: crypto.randomUUID(), email: "c@x.co", post_url: "u3", app: "juango", status: "approved" });
  const r = await send(post("promo-send", { action: "send" }, "1.1.1.1", { "x-admin-secret": "a-very-long-admin-secret-123" }),
    db, env({ PROMO_ADMIN_SECRET: "a-very-long-admin-secret-123", RESEND_API_KEY: "re", PROMO_FROM_EMAIL: "a@b.c" }), (async () => new Response("no", { status: 500 })) as typeof fetch);
  assert.equal((await r.json()).failed.length, 1);
  assert.equal(s.claims[2].status, "approved");
});

test("Email 範本有 App 名稱和連結", () => {
  const m = email("bango", "https://howweichi-app.github.io/redeem/?t=abc");
  assert.equal(m.subject, "你的校板 BanGo Pro 免費一年");
  assert.ok(m.text.includes("https://howweichi-app.github.io/redeem/?t=abc"));
});

test("CORS 預檢", async () => {
  const { db } = fakeDb();
  const r = await apply(new Request("https://x.test/promo-apply", { method: "OPTIONS", headers: { origin: "http://localhost:4173" } }), db, env());
  assert.equal(r.status, 204);
  assert.equal(r.headers.get("access-control-allow-origin"), "http://localhost:4173");
});

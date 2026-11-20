// POST promo-claim { token, platform, peek }：官網兌換頁 /redeem/?t=<token>
//   peek = true：只看狀態，不發代碼 → { status: 'fresh', app } 或已經發過 → { status: 'issued', app, platform, code, already: true }
//   peek = false：發一組對應平台的代碼 → { status: 'issued', app, platform, code, already }
// 同一個 token 只會拿到一組代碼，再打開只顯示同一組。錯誤：not_found、expired、sold_out、rate、invalid、server。
import { body, clientIp, cors, type Env, fail, json, sha256 } from "../_shared/http.ts";
import { TOKEN } from "../_shared/rules.ts";
import type { Db } from "../_shared/db.ts";

type Lookup = { id: string; app: string; status: string; expired: boolean; code: string | null; platform: string | null };

export async function handle(req: Request, db: Db, env: Env): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return fail(req, "invalid");
  const b = await body(req);
  if (!b) return fail(req, "invalid");
  if (typeof b.token !== "string" || !TOKEN.test(b.token)) return fail(req, "not_found");

  const hit = await db.rpc("promo_rate_hit", { p_ip_hash: await sha256((env("PROMO_IP_SALT") ?? "") + clientIp(req)), p_kind: "claim", p_limit: 30 });
  if (hit.error) return fail(req, "server");
  if (hit.data !== true) return fail(req, "rate");

  const found = await db.rpc("promo_claim_lookup", { p_token_hash: await sha256(b.token) });
  if (found.error) return fail(req, "server");
  const c = found.data as Lookup | null;
  if (!c) return fail(req, "not_found");
  if (c.code) return json(req, { status: "issued", app: c.app, platform: c.platform, code: c.code, already: true });
  if (c.expired) return fail(req, "expired");
  if (b.peek === true) return json(req, { status: "fresh", app: c.app });
  if (b.platform !== "ios" && b.platform !== "android") return fail(req, "invalid", "請選 iPhone 或 Android。", "platform");

  const issued = await db.rpc("promo_issue_code", { p_claim_id: c.id, p_platform: b.platform });
  if (issued.error) return fail(req, "server");
  const r = issued.data as { code?: string; platform?: string; app?: string; already?: boolean; sold_out?: boolean } | null;
  if (!r) return fail(req, "expired");
  if (r.sold_out) return fail(req, "sold_out");
  return json(req, { status: "issued", app: r.app, platform: r.platform, code: r.code, already: r.already === true });
}

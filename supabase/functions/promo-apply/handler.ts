// POST promo-apply
//   { step: 'proof', type, size, turnstile }  → { path, upload_url }：截圖的 signed upload URL（私人 bucket promo-proofs）
//   { step: 'submit', email, post_url, platform, likes, views, app, device, agreed, proof_path?, turnstile } → { ok: true }
// 錯誤：{ error, message, field? }，error 是 invalid、duplicate、closed、rate、bot、server。
// 所有欄位在這裡再檢查一次；同一個 IP 每小時最多送出 5 次（截圖 10 次）；Turnstile 驗證機器人。
import { body, clientIp, cors, type Env, fail, json, sha256, turnstileOk } from "../_shared/http.ts";
import { checkApplication, proofExt } from "../_shared/rules.ts";
import type { Db } from "../_shared/db.ts";

const LIMIT = { submit: 5, proof: 10 } as const;

export async function handle(req: Request, db: Db, env: Env, fetcher: typeof fetch = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return fail(req, "invalid");
  const b = await body(req);
  if (!b || (b.step !== "submit" && b.step !== "proof")) return fail(req, "invalid");
  const step = b.step as keyof typeof LIMIT;

  const stats = await db.rpc("promo_stats");
  if (stats.error) return fail(req, "server");
  const s = stats.data as { open: boolean; remaining: number };
  if (!s.open || s.remaining <= 0) return fail(req, "closed");

  const ip = clientIp(req);
  const hit = await db.rpc("promo_rate_hit", { p_ip_hash: await sha256((env("PROMO_IP_SALT") ?? "") + ip), p_kind: step, p_limit: LIMIT[step] });
  if (hit.error) return fail(req, "server");
  if (hit.data !== true) return fail(req, "rate");

  if (env("PROMO_SKIP_TURNSTILE") !== "1" && !(await turnstileOk(b.turnstile, ip, env("TURNSTILE_SECRET_KEY"), fetcher))) return fail(req, "bot");

  if (step === "proof") {
    const ext = proofExt(b.type, b.size);
    if (typeof ext !== "string") return fail(req, "invalid", ext.message, "proof");
    const d = new Date();
    const path = `${d.getUTCFullYear()}${String(d.getUTCMonth() + 1).padStart(2, "0")}/${crypto.randomUUID()}.${ext}`;
    const up = await db.signedUpload(path);
    if (!up) return fail(req, "server");
    return json(req, { path, upload_url: up.url });
  }

  const a = checkApplication(b);
  if ("field" in a) return fail(req, "invalid", a.message, a.field);
  const r = await db.rpc("promo_apply", {
    p_email: a.email, p_post_url: a.post_url, p_post_platform: a.post_platform, p_likes: a.likes, p_views: a.views,
    p_app: a.app, p_device: a.device, p_proof: a.proof_path,
  });
  if (r.error) return fail(req, "server");
  if (r.data === "duplicate") return fail(req, "duplicate");
  if (r.data === "closed") return fail(req, "closed");
  if (r.data !== "ok") return fail(req, "server");
  return json(req, { ok: true });
}

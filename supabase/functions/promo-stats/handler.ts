// GET promo-stats → { remaining, open }。官網活動頁的「還剩 N 名」；open 是 false 或 remaining 是 0 時，表單換成「活動已結束」。
import { cors, fail, json } from "../_shared/http.ts";
import type { Db } from "../_shared/db.ts";

export async function handle(req: Request, db: Db): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "GET" && req.method !== "POST") return fail(req, "invalid");
  const { data, error } = await db.rpc("promo_stats");
  if (error || !data) return fail(req, "server");
  const d = data as { remaining: number; open: boolean };
  return json(req, { remaining: d.open ? d.remaining : 0, open: d.open && d.remaining > 0 });
}

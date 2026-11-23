// POST /functions/v1/ai/chat/completions（OpenAI 相容）：捲字 Pro 的雲端 AI，轉送到 Agnes。
//   Android 的 Pro 用戶、不支援 Apple Intelligence 的 iPhone 的 Pro 用戶會用到。
//   App 用「登入的 access token」當 Bearer，不帶任何 AI 金鑰；金鑰只存在 Secrets 的 AGNES_API_KEY。
//   body 和 OpenAI chat/completions 一樣（messages、temperature、response_format…），模型固定用 AI_MODEL。
// 錯誤：{ error: { code, message } }，code 是 unauthorized、not_pro、quota、invalid、upstream、server。
// 邏輯不依賴 Deno（env、驗證身分、資料庫、fetch 都由外面傳進來），可以用 node 測。
import type { Db } from "../_shared/db.ts";
import type { Env } from "../_shared/http.ts";

export const DEFAULTS = {
  base: "https://apihub.agnes-ai.com/v1",
  model: "agnes-3.0-flash",
  monthly: 300,
  maxBody: 60_000,
  maxTokens: 2_000,
};

const MESSAGES: Record<string, string> = {
  unauthorized: "請先登入",
  not_pro: "雲端 AI 是捲字 Pro 的功能",
  quota: "這個月的雲端 AI 次數用完了，下個月會重新計算",
  invalid: "要求的格式不對",
  upstream: "AI 服務暫時沒有回應，請稍後再試",
  server: "伺服器出了一點問題，請稍後再試",
};
const STATUS: Record<string, number> = { unauthorized: 401, not_pro: 403, quota: 429, invalid: 400, upstream: 502, server: 500 };

const HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function fail(code: string): Response {
  return new Response(JSON.stringify({ error: { code, message: MESSAGES[code] } }), {
    status: STATUS[code] ?? 400,
    headers: { ...HEADERS, "Content-Type": "application/json; charset=utf-8" },
  });
}

/** 從 access token 拿到 user id；token 不對就是 null */
export type WhoAmI = (token: string) => Promise<string | null>;

export async function handle(req: Request, db: Db, env: Env, who: WhoAmI, fetcher: typeof fetch = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: HEADERS });
  if (req.method !== "POST") return fail("invalid");
  const path = new URL(req.url).pathname;
  if (!path.endsWith("/chat/completions")) return fail("invalid");

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const user = token ? await who(token) : null;
  if (!user) return fail("unauthorized");

  const text = await req.text();
  if (text.length > DEFAULTS.maxBody) return fail("invalid");
  let b: Record<string, unknown>;
  try {
    const v = JSON.parse(text);
    if (!v || typeof v !== "object" || Array.isArray(v) || !Array.isArray(v.messages) || v.messages.length === 0) return fail("invalid");
    b = v;
  } catch { return fail("invalid"); }

  const key = env("AGNES_API_KEY");
  if (!key) return fail("server");

  const limit = Number(env("AI_MONTHLY_LIMIT") ?? DEFAULTS.monthly) || DEFAULTS.monthly;
  const take = await db.rpc("ai_take", { p_user: user, p_limit: limit });
  if (take.error) return fail("server");
  if (take.data === "not_pro") return fail("not_pro");
  if (take.data === "quota") return fail("quota");
  if (take.data !== "ok") return fail("server");

  // 只轉送這些欄位；模型和上限由伺服器決定
  const forward: Record<string, unknown> = {
    model: env("AI_MODEL") ?? DEFAULTS.model,
    messages: b.messages,
    max_tokens: Math.min(Number(b.max_tokens) || DEFAULTS.maxTokens, DEFAULTS.maxTokens),
  };
  if (typeof b.temperature === "number") forward.temperature = b.temperature;
  if (b.response_format && typeof b.response_format === "object") forward.response_format = b.response_format;

  let r: Response;
  try {
    r = await fetcher(`${env("AI_BASE_URL") ?? DEFAULTS.base}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify(forward),
    });
  } catch { return fail("upstream"); }
  if (!r.ok) return fail("upstream");
  return new Response(await r.text(), { status: 200, headers: { ...HEADERS, "Content-Type": "application/json; charset=utf-8" } });
}

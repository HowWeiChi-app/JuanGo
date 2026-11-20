// Edge Function 共用：CORS、JSON 回應、取 IP、雜湊、Cloudflare Turnstile 驗證。不依賴 Deno，node 也能跑。

// 只讓官網（和本機預覽）呼叫
const ORIGINS = ["https://howweichi-app.github.io", "http://localhost:4173", "http://127.0.0.1:4173"];

export function cors(req: Request): Record<string, string> {
  const o = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

export function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { ...cors(req), "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

export const MESSAGES: Record<string, string> = {
  duplicate: "已經申請過了。同一個 Email 或同一篇貼文只能申請一次。",
  closed: "活動已經結束了，謝謝你的參與。",
  rate: "送出太多次了，請一個小時後再試。",
  invalid: "有欄位不符合規則，請回去檢查。",
  bot: "沒有通過機器人檢查，請重新整理再試一次。",
  expired: "這個啟用連結已經過期了（寄出後 30 天內有效）。",
  redeemed: "這個連結的代碼已經兌換過了。",
  sold_out: "這個平台的兌換碼發完了。",
  not_found: "找不到這個啟用連結，請確認網址跟信裡的一樣。",
  server: "伺服器出了一點問題，請稍後再試。",
};
const STATUS: Record<string, number> = { duplicate: 409, closed: 410, rate: 429, invalid: 400, bot: 403, expired: 410, redeemed: 410, sold_out: 409, not_found: 404, server: 500 };

export function fail(req: Request, code: string, message?: string, field?: string): Response {
  return json(req, { error: code, message: message ?? MESSAGES[code], ...(field ? { field } : {}) }, STATUS[code] ?? 400);
}

export async function body(req: Request): Promise<Record<string, unknown> | null> {
  if (!(req.headers.get("content-type") ?? "").includes("application/json")) return null;
  const text = await req.text();
  if (text.length > 10_000) return null;
  try {
    const v = JSON.parse(text);
    return v && typeof v === "object" && !Array.isArray(v) ? v : null;
  } catch { return null; }
}

export function clientIp(req: Request): string {
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? req.headers.get("x-real-ip") ?? "unknown";
}

export async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// 一次性 token：32 bytes，base64url
export function newToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function turnstileOk(token: unknown, ip: string, secret: string | undefined, fetcher = fetch): Promise<boolean> {
  if (!secret) return false;
  if (typeof token !== "string" || !token || token.length > 2048) return false;
  const form = new FormData();
  form.append("secret", secret);
  form.append("response", token);
  if (ip !== "unknown") form.append("remoteip", ip);
  try {
    const r = await fetcher("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form });
    const d = await r.json();
    return d.success === true;
  } catch { return false; }
}

export type Env = (k: string) => string | undefined;

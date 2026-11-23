// 用 node 測雲端 AI 的 Edge Function：node --test supabase/functions/test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { handle } from "../ai/handler.ts";
import type { Db } from "../_shared/db.ts";

function setup(opts: { pro?: boolean; limit?: number } = {}) {
  const calls: Record<string, number> = {};
  const sent: { url: string; body: any; auth: string }[] = [];
  const db: Db = {
    async rpc(fn, a: any = {}) {
      assert.equal(fn, "ai_take");
      if (opts.pro === false) return { data: "not_pro", error: null };
      const n = calls[a.p_user] ?? 0;
      if (n >= a.p_limit) return { data: "quota", error: null };
      calls[a.p_user] = n + 1;
      return { data: "ok", error: null };
    },
    signedUpload: async () => null,
    removeFiles: async () => {},
  };
  const env = (k: string) => ({ AGNES_API_KEY: "sk-test", AI_MONTHLY_LIMIT: String(opts.limit ?? 2) } as Record<string, string>)[k];
  const who = async (t: string) => (t === "good" ? "user-1" : null);
  const fetcher = (async (url: string, init: any) => {
    sent.push({ url, body: JSON.parse(init.body), auth: init.headers.Authorization });
    return new Response(JSON.stringify({ choices: [{ message: { content: "hi" } }] }), { status: 200 });
  }) as unknown as typeof fetch;
  const call = (token: string | null, body: unknown = { messages: [{ role: "user", content: "x" }], model: "gpt-x", max_tokens: 99999 }) =>
    handle(new Request("https://p.supabase.co/functions/v1/ai/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body),
    }), db, env, who, fetcher);
  return { call, sent };
}

test("Pro 帳號轉送到 Agnes，模型和上限由伺服器決定", async () => {
  const { call, sent } = setup();
  const r = await call("good");
  assert.equal(r.status, 200);
  assert.equal((await r.json()).choices[0].message.content, "hi");
  assert.equal(sent[0].url, "https://apihub.agnes-ai.com/v1/chat/completions");
  assert.equal(sent[0].auth, "Bearer sk-test");
  assert.equal(sent[0].body.model, "agnes-3.0-flash");
  assert.equal(sent[0].body.max_tokens, 2000);
});

test("沒登入、沒有 Pro、配額用完", async () => {
  assert.equal((await setup().call(null)).status, 401);
  assert.equal((await setup().call("bad")).status, 401);
  assert.equal((await setup({ pro: false }).call("good")).status, 403);
  const s = setup({ limit: 1 });
  assert.equal((await s.call("good")).status, 200);
  const r = await s.call("good");
  assert.equal(r.status, 429);
  assert.equal((await r.json()).error.code, "quota");
  assert.equal(s.sent.length, 1);
});

test("格式不對不扣次數", async () => {
  const s = setup();
  assert.equal((await s.call("good", { messages: [] })).status, 400);
  assert.equal(s.sent.length, 0);
});

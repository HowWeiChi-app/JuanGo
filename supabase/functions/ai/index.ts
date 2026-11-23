// Supabase Edge Function 進入點。邏輯在 handler.ts（不依賴 Deno，可以用 node 測）。
import { createClient } from "npm:@supabase/supabase-js@2";
import { serviceDb } from "../_shared/client.ts";
import { handle } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const auth = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } }).auth;
const db = serviceDb();

Deno.serve((req) =>
  handle(req, db, (k) => Deno.env.get(k), async (token) => {
    const { data, error } = await auth.getUser(token);
    return error || !data.user ? null : data.user.id;
  })
);

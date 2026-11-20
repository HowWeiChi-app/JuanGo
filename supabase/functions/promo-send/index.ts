// Supabase Edge Function 進入點。邏輯在 handler.ts（不依賴 Deno，可以用 node 測）。
import { serviceDb } from "../_shared/client.ts";
import { gmail } from "../_shared/mail.ts";
import { handle } from "./handler.ts";

const db = serviceDb();
const mail = gmail();
Deno.serve((req) => handle(req, db, (k) => Deno.env.get(k), mail));

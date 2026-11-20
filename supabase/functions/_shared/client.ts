// 真正的 Supabase client（service role，只在 Edge Function 裡用）。
import { createClient } from "npm:@supabase/supabase-js@2";
import type { Db } from "./db.ts";

export function serviceDb(): Db {
  const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const bucket = sb.storage.from("promo-proofs");
  return {
    rpc: async (fn, args) => {
      const { data, error } = await sb.rpc(fn, args ?? {});
      return { data, error: error ? { message: error.message } : null };
    },
    signedUpload: async (path) => {
      const { data, error } = await bucket.createSignedUploadUrl(path);
      return error || !data ? null : { url: data.signedUrl };
    },
    removeFiles: async (paths) => {
      for (let i = 0; i < paths.length; i += 100) await bucket.remove(paths.slice(i, i + 100));
    },
  };
}

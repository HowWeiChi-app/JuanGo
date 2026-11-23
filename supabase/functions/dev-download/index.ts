// Spends a one-time JuanGo download link and answers with a download URL that works for 10 minutes.
// The landing page https://howweichi-app.github.io/juango/download/?t=<token> posts { token } here when the
// button is pressed, so chat apps that preview the link don't use it up. Deploy with JWT verification off.
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const { token } = await req.json().catch(() => ({}));
  if (typeof token !== "string" || !/^[0-9a-f]{24}$/.test(token)) return json({ error: "invalid" }, 400);

  // the platform injects the project's own key; nothing secret lives in this file
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
    Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}"))[0] as string;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, key);
  const { data, error } = await db.rpc("dev_link_use", { p_token: token });
  if (error) return json({ error: "server" }, 500);
  if (!data) return json({ error: "used" }, 410);
  const signed = await db.storage.from("dev-builds").createSignedUrl(data.path, 600, { download: "JuanGo-dev.apk" });
  if (signed.error) return json({ error: "server" }, 500);
  return json({ url: signed.data.signedUrl, version: data.version, build: data.build });
});

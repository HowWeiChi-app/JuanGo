// 可疑異動 email 通知（supabase/audit.sql）。pg_cron 每 8 分鐘呼叫一次：
// 上次之後有可疑異動才寄信到 ALERT_EMAIL（沒設就寄到 GMAIL_USER）；一般的異動不寄。
// 不用驗證身分（verify_jwt = false）：誰叫都只會把可疑異動寄給開發者，3 分鐘內重叫不會再寄。
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6";

type Row = {
  at: string; tbl: string; op: string; id: string | null; name: string | null; role: string | null;
  ip: string | null; row: string | null; changed: string | null; reason: string | null;
};

const ops: Record<string, string> = { INSERT: "新增", UPDATE: "修改", DELETE: "刪除" };
const roles: Record<string, string> = { anon: "沒登入", authenticated: "登入的使用者", service_role: "伺服器金鑰" };
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

function line(r: Row): string {
  const who = r.id ? `${r.name ?? ""}（${r.id}）` : roles[r.role ?? ""] ?? `後台／排程（${r.role}）`;
  const what = `${ops[r.op] ?? r.op} ${r.tbl.replace(/^public\./, "")}${r.row ? ` ${r.row}` : ""}`;
  const cols = r.changed ? `：${r.changed}` : "";
  const ip = r.ip ? ` IP ${r.ip}` : "";
  return `⚠️ ${r.reason}｜${r.at} ${who} ${what}${cols}${ip}`;
}

Deno.serve(async () => {
  const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
  const to = Deno.env.get("ALERT_EMAIL") ?? user;
  if (!user || !pass || !to) return new Response("mail not set", { status: 500 });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await sb.rpc("audit_alert_take");
  if (error) return new Response(error.message, { status: 500 });
  const rows: Row[] = data?.rows ?? [];
  const bursts: { id: string | null; name: string | null; ip: string | null; n: number }[] = data?.bursts ?? [];
  if (!rows.length && !bursts.length) return new Response("nothing suspicious");

  const lines = [
    ...bursts.map((b) => `⚠️ 短時間大量異動｜${b.id ? `${b.name ?? ""}（${b.id}）` : `IP ${b.ip}`} 這 8 分鐘改了 ${b.n} 次`),
    ...rows.map(line),
  ];
  const subject = `⚠️ 捲字資料庫：${lines.length} 筆可疑異動` + (rows.length >= 100 ? "（只列前 100 筆）" : "");
  const text = lines.join("\n") + "\n\n完整紀錄：Supabase › Table Editor › 管理 › 可疑異動、異動紀錄";
  const html = `<div style="font:14px/1.6 -apple-system,sans-serif">${
    lines.map((l) => `<div style="color:#b42318">${esc(l)}</div>`).join("")
  }<p style="color:#666">完整紀錄：Supabase › Table Editor › 管理 › 可疑異動、異動紀錄</p></div>`;

  const t = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
  await t.sendMail({ from: { name: "捲字 JuanGo 監控", address: user }, to, subject, text, html });
  return new Response(`sent ${rows.length}`);
});

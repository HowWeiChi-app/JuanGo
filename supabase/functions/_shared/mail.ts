// 用 Gmail 寄信，跟捲字登入連結用同一個 Google 帳號。
// 要先在那個 Google 帳號開兩步驟驗證，再建立「應用程式密碼」，填進 secrets：GMAIL_USER、GMAIL_APP_PASSWORD。
// Supabase Edge Function 不能連 25 和 587 埠，所以用 465（SSL）。Gmail 一般帳號一天大約可以寄 500 封。
import nodemailer from "npm:nodemailer@6";
import type { Mail } from "./mail-type.ts";

export function gmail(): Mail | null {
  const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!user || !pass) return null;
  const name = Deno.env.get("PROMO_FROM_NAME") ?? "HowWeiChi";
  const t = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
  return async (m) => {
    await t.sendMail({ from: { name, address: user }, to: m.to, subject: m.subject, text: m.text, html: m.html });
  };
}

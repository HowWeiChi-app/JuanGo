// 活動申請的檢查規則。跟官網 site/js/promo-api.js 一樣，前端的檢查可以被繞過，所以這裡再檢查一次。
// 這個檔不依賴 Deno 或 Supabase，可以用 node 直接測（supabase/functions/test/）。

export const LIKES_MIN = 100;
export const VIEWS_MIN = 10_000;
export const PROOF_TYPES = ["image/jpeg", "image/png", "image/heic", "image/heif"];
export const PROOF_MAX = 5 * 1024 * 1024;

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
export function checkEmail(v: unknown): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (!s) return "請填 Email。";
  if (!EMAIL.test(s) || s.length > 254) return "這個 Email 的格式不對。";
  return "";
}

export type Post = { url: string; platform: "instagram" | "threads" } | { error: string };

// 只收一般貼文：instagram.com/p/、/reel/（可以帶帳號名稱），threads.net、threads.com 的 /@帳號/post/。限動直接拒絕。
export function parsePost(raw: unknown): Post {
  let s = typeof raw === "string" ? raw.trim() : "";
  if (!s) return { error: "請貼上貼文連結。" };
  if (s.length > 300) return { error: "連結太長了。" };
  if (!/^https?:\/\//i.test(s)) s = "https://" + s;
  let u: URL;
  try { u = new URL(s); } catch { return { error: "這不是網址。" }; }
  const host = u.hostname.toLowerCase().replace(/^(www|m)\./, "");
  const path = u.pathname.replace(/\/+$/, "");
  if (host === "instagram.com" || host === "instagr.am") {
    if (/^\/stories\//i.test(path) || /^\/s\//i.test(path)) return { error: "這是限時動態的連結，限動不算。" };
    const m = path.match(/^\/(?:[\w.]+\/)?(p|reel)\/([\w-]{5,})$/i);
    if (!m) return { error: "這不是一般貼文的連結。" };
    return { url: `https://www.instagram.com/${m[1].toLowerCase()}/${m[2]}/`, platform: "instagram" };
  }
  if (host === "threads.net" || host === "threads.com") {
    const m = path.match(/^\/@([\w.]+)\/post\/([\w-]{5,})$/i);
    if (!m) return { error: "這不是 Threads 貼文的連結。" };
    return { url: `https://www.threads.com/@${m[1]}/post/${m[2]}`, platform: "threads" };
  }
  return { error: "只收 Instagram 或 Threads 的貼文連結。" };
}

const isCount = (n: unknown): n is number => Number.isInteger(n) && (n as number) >= 0 && (n as number) < 1e9;
export const reached = (likes: number, views: number) => likes >= LIKES_MIN || views >= VIEWS_MIN;

export type Application = {
  email: string; post_url: string; post_platform: "instagram" | "threads"; likes: number; views: number;
  app: "juango" | "bango"; device: "ios" | "android"; proof_path: string | null;
};

// 檢查整份申請。成功回傳正規化的資料，失敗回傳 { field, message }。
export function checkApplication(b: Record<string, unknown>): Application | { field: string; message: string } {
  const e = checkEmail(b.email);
  if (e) return { field: "email", message: e };
  const post = parsePost(b.post_url);
  if ("error" in post) return { field: "post", message: post.error };
  // 平台以連結為準，表單上選的平台只是讓使用者確認
  if (!isCount(b.likes)) return { field: "likes", message: "讚數要是整數。" };
  if (!isCount(b.views)) return { field: "views", message: "瀏覽數要是整數。" };
  if (!reached(b.likes, b.views)) return { field: "views", message: `還沒達到門檻（${LIKES_MIN} 個讚或 ${VIEWS_MIN.toLocaleString("en-US")} 次瀏覽）。` };
  if (b.app !== "juango" && b.app !== "bango") return { field: "app", message: "請選捲字或校板。" };
  if (b.device !== "ios" && b.device !== "android") return { field: "device", message: "請選 iPhone 或 Android。" };
  if (b.agreed !== true) return { field: "agree", message: "請先勾選，確認貼文符合規則。" };
  let proof: string | null = null;
  if (b.proof_path !== undefined && b.proof_path !== null && b.proof_path !== "") {
    if (typeof b.proof_path !== "string" || !PROOF_PATH.test(b.proof_path)) return { field: "proof", message: "截圖上傳有問題，請重新選一次。" };
    proof = b.proof_path;
  }
  return {
    email: (b.email as string).trim().toLowerCase(), post_url: post.url, post_platform: post.platform,
    likes: b.likes, views: b.views, app: b.app, device: b.device, proof_path: proof,
  };
}

// 截圖路徑由 promo-apply 產生：年月/隨機 UUID.副檔名，申請時只接受這個格式
export const PROOF_PATH = /^\d{6}\/[0-9a-f-]{36}\.(jpg|png|heic)$/;
export function proofExt(type: unknown, size: unknown): string | { message: string } {
  if (typeof type !== "string" || !PROOF_TYPES.includes(type)) return { message: "只收 JPG、PNG 或 HEIC 圖片。" };
  if (!Number.isInteger(size) || (size as number) <= 0 || (size as number) > PROOF_MAX) return { message: "圖片要在 5MB 以內。" };
  return type === "image/jpeg" ? "jpg" : type === "image/png" ? "png" : "heic";
}

export const TOKEN = /^[\w-]{20,128}$/;

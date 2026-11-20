// 寄信的介面：handler 只用這個，測試時換成假的。真的在 mail.ts（Gmail SMTP）。
export type Mail = (m: { to: string; subject: string; text: string; html: string }) => Promise<void>;

// 資料庫的介面：handler 只用到這些，測試時換成假的。真的由 client.ts 用 service role 建立。
export type Rpc = (fn: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
export type Db = {
  rpc: Rpc;
  signedUpload: (path: string) => Promise<{ url: string } | null>;
  removeFiles: (paths: string[]) => Promise<void>;
};

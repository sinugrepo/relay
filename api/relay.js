// api/relay.js — adapter Vercel Edge. Konvensi Vercel: file di bawah api/
// otomatis menjadi endpoint (URL: https://<project>.vercel.app/api/relay).
export const config = { runtime: "edge" };

import { handleRelay } from "../src/core.js";

export default async function handler(request) {
  return handleRelay(request);
}

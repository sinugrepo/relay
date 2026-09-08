// workers/worker.js — adapter Cloudflare Workers.
// Deploy: npx wrangler deploy   (konfigurasi di wrangler.toml)
// URL: https://<nama>.workers.dev/api/relay  (path diabaikan, routing via
// header x-relay-target/x-relay-path seperti di Vercel).

import { handleRelay } from "../src/core.js";

export default {
  async fetch(request) {
    return handleRelay(request);
  },
};

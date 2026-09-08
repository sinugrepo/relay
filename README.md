# opencode-relay

Pass-through relay generik ke upstream OpenCode. **Satu core (`src/core.js`), dua runtime**:

| Runtime | Entry point | URL contoh |
|---|---|---|
| Vercel Edge | `api/relay.js` | `https://relay-fix.vercel.app/api/relay` |
| Cloudflare Workers | `workers/worker.js` | `https://opencode-relay.workers.dev/api/relay` |

Backend (`backend_api.py`) memakai relay lewat 2 header — path URL diabaikan:

- `x-relay-target`: origin upstream, mis. `https://opencode.ai`
- `x-relay-path`: path upstream, mis. `/zen/v1/responses`

Tambahkan URL deployment ke `RELAY_URLS` (env, koma-dipisah) agar ikut rotasi.

## Kenapa dua runtime?

- **Vercel Edge**: wajib kirim byte pertama < ~25 dtk, lalu boleh streaming s.d. ~300 dtk. `core.js` memenuhi ini via preamble (`: relay-connected`) + heartbeat (`: ping` tiap 10 dtk) khusus respons SSE. Non-SSE (JSON) diteruskan utuh tanpa heartbeat.
- **Cloudflare Workers**: tanpa batas wall-clock (hanya 10 ms CPU/request; relay ini I/O-bound jadi aman) — stream sepanjang apa pun tidak dibunuh platform. Free tier 100rb req/hari.

## Deploy

```bash
# Vercel (per project/deployment)
vercel --prod

# Cloudflare (butuh login sekali: npx wrangler login)
npm install
npm run deploy:cf
```

## Verifikasi tiap deployment baru

```bash
# 1) IP egress (harus beda antar deployment agar rotasi berguna):
curl -s "https://<relay>/api/relay" \
  -H "x-relay-target: https://api.ipify.org" \
  -H "x-relay-path: /?format=json"

# 2) Streaming tidak dibunuh di tengah jalan: panggil via backend dengan
#    model yang generasinya > 30 dtk, pastikan tak ada log STREAM-TIMEOUT.
```

## Batas yang perlu diingat

- Vercel: byte pertama < 25 dtk (diatasi heartbeat), maks ~300 dtk streaming.
- Cloudflare free: 100rb req/hari per akun (bukan per Worker) — sebar ke
  beberapa akun bila perlu; 50 subrequest/invocation (relay pakai 1).
- Jangan tambah komputasi berat ke `core.js` (risiko jebol 10 ms CPU di CF).

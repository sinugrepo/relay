// src/core.js — logika relay bersama untuk Vercel Edge & Cloudflare Workers.
//
// Hanya memakai Web Standard API (Request/Response/Headers/TransformStream,
// fetch, setInterval) sehingga berjalan identik di kedua runtime tanpa
// perubahan. Adapter tipis ada di:
//   - api/relay.js        (Vercel Edge)
//   - workers/worker.js   (Cloudflare Workers)
//
// Kontrak dengan backend (backend_api.py):
//   - Header `x-relay-target`: origin upstream, mis. "https://opencode.ai"
//   - Header `x-relay-path`: path upstream, mis. "/zen/v1/responses"
//   - Method/body/headers lain diteruskan apa adanya (kecuali hop-by-hop).
//
// Aturan platform yang WAJIB dipatuhi:
//   Vercel Edge harus mengirim byte pertama < ~25 dtk (lalu boleh lanjut
//   streaming s.d. ~300 dtk). Karena itu respons SSE dibungkus preamble +
//   heartbeat; non-SSE (JSON biasa) diteruskan utuh tanpa heartbeat.

// Header hop-by-hop: hanya berlaku untuk satu hop, tidak boleh diteruskan
// dari klien ke upstream maupun dari upstream ke respons.
const HOP_BY_HOP = [
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "content-length",
];

// Header routing/edge yang tidak relevan untuk upstream.
const STRIP_HEADERS = [
  ...HOP_BY_HOP,
  "x-relay-target",
  "x-relay-path",
  "host",
  "x-forwarded-for",
  "x-forwarded-host",
  "x-forwarded-proto",
  "x-forwarded-port",
  "x-forwarded-ssl",
  "forwarded",
  "x-real-ip",
  "x-vercel-forwarded-for",
  "x-vercel-proxied-for",
  "via",
  "cf-connecting-ip",
  "cf-ray",
  "true-client-ip",
];

const SSE_PREAMBLE = ": relay-connected\n\n";
const SSE_HEARTBEAT = ": ping\n\n";
const HEARTBEAT_MS = 10000;

function jsonError(message, status) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Tangani satu request relay. Mengembalikan Response (streaming bila SSE).
 * @param {Request} request
 * @returns {Promise<Response>}
 */
export async function handleRelay(request) {
  const target = request.headers.get("x-relay-target");
  const path = request.headers.get("x-relay-path") || "/";
  if (!target) {
    return jsonError("Missing x-relay-target header", 400);
  }

  let url;
  try {
    url = new URL(target + path);
  } catch {
    return jsonError("Invalid x-relay-target/x-relay-path", 400);
  }

  const headers = new Headers(request.headers);
  for (const h of STRIP_HEADERS) headers.delete(h);

  // Kompresi hanya aktif jika klien eksplisit memintanya via accept-encoding.
  // Kalau tidak, paksa "identity" supaya runtime tidak auto-decompress dan
  // header Content-Encoding tidak pernah bocor ke klien tanpa body yang
  // benar-benar terkompresi.
  const clientAe = request.headers.get("accept-encoding");
  const wantCompression =
    !!clientAe && !clientAe.includes("identity") && !clientAe.includes("q=0");
  if (!wantCompression) headers.set("accept-encoding", "identity");

  // Body REQUEST boleh di-buffer (payload chat kecil). Yang wajib streaming
  // hanya body RESPONSE.
  let body;
  try {
    body = ["GET", "HEAD"].includes(request.method)
      ? undefined
      : await request.arrayBuffer();
  } catch {
    return jsonError("Failed to read request body", 400);
  }

  let upstream;
  try {
    upstream = await fetch(url, {
      method: request.method,
      headers,
      body,
      // Jangan ikuti redirect: teruskan status 3xx + location apa adanya.
      redirect: "manual",
      // Client disconnect/abort membatalkan fetch upstream (stream tidak
      // dibiarkan jalan sampai habis).
      signal: request.signal,
    });
  } catch (err) {
    return jsonError(`Relay fetch failed: ${String(err)}`, 502);
  }

  // KUNCI: teruskan upstream.body sebagai ReadableStream.
  // JANGAN pernah `await upstream.text()` — itu membuffer seluruh stream.
  // Semua response header upstream diteruskan (kecuali hop-by-hop),
  // termasuk set-cookie, retry-after, location, dsb.
  const responseHeaders = new Headers();
  for (const [k, v] of upstream.headers) {
    const lk = k.toLowerCase();
    if (lk === "set-cookie") continue;
    if (!HOP_BY_HOP.includes(lk)) responseHeaders.set(k, v);
  }
  if (typeof upstream.headers.getSetCookie === "function") {
    for (const c of upstream.headers.getSetCookie()) {
      responseHeaders.append("set-cookie", c);
    }
  }
  if (!responseHeaders.has("content-type")) {
    responseHeaders.set("content-type", "text/event-stream");
  }
  // Content-Encoding hanya diteruskan jika klien benar-benar memintanya.
  if (!wantCompression) responseHeaders.delete("content-encoding");
  responseHeaders.set("Cache-Control", "no-cache, no-transform");
  responseHeaders.set("X-Accel-Buffering", "no");

  const contentType = (upstream.headers.get("content-type") || "").toLowerCase();
  const isStream = contentType.includes("text/event-stream");

  if (!isStream || !upstream.body) {
    // Non-SSE (JSON biasa dsb.): teruskan apa adanya TANPA heartbeat —
    // heartbeat (`:`) hanya valid di dalam event-stream.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders,
    });
  }

  // SSE: byte pertama keluar SEGERA (< 25 dtk, syarat Edge Vercel agar boleh
  // lanjut streaming s.d. ~300 dtk) + heartbeat tiap 10 dtk selama menunggu
  // chunk upstream. Tanpa ini, stream yang chunk pertamanya datang > 25 dtk
  // langsung mati FUNCTION_INVOCATION_TIMEOUT di Vercel. Di Cloudflare
  // Workers pola yang sama tidak merugikan (tanpa wall-time limit).
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  const writeComment = (text) =>
    writer.write(encoder.encode(text)).catch(() => {});
  writeComment(SSE_PREAMBLE); // first byte segera
  const heartbeat = setInterval(() => writeComment(SSE_HEARTBEAT), HEARTBEAT_MS);
  (async () => {
    const reader = upstream.body.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        await writer.write(value);
      }
    } catch {
      try {
        await reader.cancel();
      } catch {}
    } finally {
      clearInterval(heartbeat);
      try {
        await writer.close();
      } catch {}
    }
  })();

  return new Response(readable, {
    status: upstream.status,
    headers: responseHeaders,
  });
}

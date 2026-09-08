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
//   streaming s.d. ~300 dtk). Karena itu request streaming (body JSON dengan
//   `"stream": true`) langsung mengembalikan SSE preamble TANPA menunggu
//   fetch upstream selesai — TTFB upstream (antrean/model reasoning) sering
//   > 25 dtk dan `await fetch()` sebelum Response adalah penyebab
//   504 FUNCTION_INVOCATION_TIMEOUT beruntun di log backend.
//   Non-streaming (JSON biasa) tetap menunggu fetch agar status HTTP
//   upstream (429/500/dll) diteruskan utuh untuk failover backend.

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

function sseHeaders() {
  return new Headers({
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-transform",
    "X-Accel-Buffering": "no",
  });
}

/**
 * Deteksi request streaming dari body JSON yang sudah di-buffer.
 * Backend selalu mengirim `{"stream": true, ...}` untuk SSE.
 * @param {ArrayBuffer|undefined} bodyBuf
 * @returns {boolean}
 */
function isStreamRequest(bodyBuf) {
  if (!bodyBuf || bodyBuf.byteLength === 0 || bodyBuf.byteLength > 2 * 1024 * 1024) {
    return false;
  }
  try {
    const text = new TextDecoder().decode(bodyBuf);
    if (!text.includes('"stream"')) return false;
    const json = JSON.parse(text);
    return !!json && json.stream === true;
  } catch {
    return false;
  }
}

/**
 * Tulis event `relay.error` yang dimengerti backend untuk failover.
 * Backend (3 generator SSE) mencegat `{"type":"relay.error",...}` SEBELUM
 * payload terkirim dan melanjutkan ke target berikutnya — jadi status
 * upstream yang gagal tetap memicu rotasi walau HTTP relay sudah 200
 * (konsekuensi early-return).
 */
function relayErrorEvent(status, body) {
  return `data: ${JSON.stringify({
    type: "relay.error",
    status,
    body: String(body || "").slice(0, 500),
  })}\n\n`;
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

  // ===== JALUR STREAMING: jawab SSE SEGERA, fetch jalan di background =====
  // Perbaikan bug 504 beruntun: versi lama `await fetch()` dulu — kalau TTFB
  // upstream > 25 dtk (muse-spark reasoning/antrean), Edge dibunuh sebelum
  // preamble sempat dikirim. Di sini byte pertama (< 1 ms) + heartbeat 10 dtk
  // menjaga Edge tetap hidup s.d. ~300 dtk sambil menunggu upstream.
  if (isStreamRequest(body)) {
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const encoder = new TextEncoder();
    let closed = false;
    const safeWrite = (chunk) => {
      if (closed) return Promise.resolve();
      return writer.write(chunk).catch(() => {});
    };
    safeWrite(encoder.encode(SSE_PREAMBLE));
    const heartbeat = setInterval(
      () => safeWrite(encoder.encode(SSE_HEARTBEAT)),
      HEARTBEAT_MS
    );
    const finish = async () => {
      clearInterval(heartbeat);
      if (!closed) {
        closed = true;
        try {
          await writer.close();
        } catch {}
      }
    };

    (async () => {
      let upstream;
      try {
        upstream = await fetch(url, {
          method: request.method,
          headers,
          body,
          redirect: "manual",
          signal: request.signal,
        });
      } catch (err) {
        await safeWrite(encoder.encode(relayErrorEvent(502, `Relay fetch failed: ${String(err)}`)));
        await finish();
        return;
      }
      if (upstream.status !== 200) {
        let detail = "";
        try {
          detail = (await upstream.text()).slice(0, 500);
        } catch {}
        await safeWrite(encoder.encode(relayErrorEvent(upstream.status, detail)));
        await finish();
        return;
      }
      const contentType = (upstream.headers.get("content-type") || "").toLowerCase();
      if (!contentType.includes("text/event-stream") || !upstream.body) {
        // Upstream me-buffer jadi satu JSON utuh: bungkus sebagai satu event
        // SSE agar loop SSE backend bisa mengonversinya (backend juga
        // menangani objek response penuh di dalam event SSE).
        try {
          const text = await upstream.text();
          await safeWrite(encoder.encode(`data: ${text}\n\n`));
          await safeWrite(encoder.encode("data: [DONE]\n\n"));
        } catch {}
        await finish();
        return;
      }
      try {
        const reader = upstream.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          await safeWrite(value);
        }
      } catch {
        // Upstream terputus mid-stream: tutup saja; backend memutuskan
        // retry (belum ada payload) vs error-chunk (payload sudah jalan).
      }
      await finish();
    })();

    return new Response(readable, { status: 200, headers: sseHeaders() });
  }

  // ===== JALUR NON-STREAMING: perilaku lama (status diteruskan utuh) =====
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

  // SSE yang lolos deteksi body (mis. GET stream tanpa body): pipe dengan
  // preamble seperti biasa. Catatan: kasus ini jarang — mayoritas streaming
  // adalah POST dengan stream:true dan sudah ditangani jalur early-return.
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

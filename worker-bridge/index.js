const MAX_JSON_BYTES = 64 * 1024;
const RECORDING_ID = /^[A-Za-z0-9_-]{8,160}$/;

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function allowedOrigin(request, env) {
  const origin = request.headers.get("origin");
  if (!origin) return null;
  const configured = String(env.ALLOWED_ORIGINS || "").split(",").map((item) => item.trim()).filter(Boolean);
  for (const item of configured) {
    if (item === origin) return origin;
    if (item.endsWith(":*")) {
      try {
        const expected = new URL(item.slice(0, -2));
        const actual = new URL(origin);
        if (expected.protocol === actual.protocol && expected.hostname === actual.hostname) return origin;
      } catch { /* Ignore malformed configuration entries. */ }
    }
  }
  return null;
}

function responseHeaders(request, env) {
  const headers = new Headers({
    "access-control-allow-methods": "GET,HEAD,POST,OPTIONS",
    "access-control-allow-headers": "authorization,content-type,range,if-range,if-none-match,if-modified-since,x-correlation-id",
    "access-control-expose-headers": "content-length,content-range,accept-ranges,etag,last-modified,x-recording-parts,x-recording-part",
    "access-control-max-age": "86400",
    "cache-control": "private, no-store",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "vary": "Origin",
  });
  const origin = allowedOrigin(request, env);
  if (origin) headers.set("access-control-allow-origin", origin);
  return headers;
}

function json(request, env, body, status = 200) {
  const headers = responseHeaders(request, env);
  headers.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(body), { status, headers });
}

function requireEnvironment(env) {
  const missing = [];
  if (!env.PRIVATE_D1_WORKER?.fetch) missing.push("PRIVATE_D1_WORKER service binding");
  for (const name of ["PRIVATE_WORKER_API_KEY", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "ALLOWED_ORIGINS"]) {
    if (!String(env[name] || "").trim()) missing.push(name);
  }
  if (missing.length) throw new HttpError(503, `Missing configuration: ${missing.join(", ")}.`);
}

function bearerToken(request) {
  const authorization = String(request.headers.get("authorization") || "");
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match?.[1]) throw new HttpError(401, "Sign in to the Ricochet report first.");
  return match[1].trim();
}

async function verifyReportUser(request, env) {
  const token = bearerToken(request);
  const endpoint = `${String(env.SUPABASE_URL).replace(/\/$/, "")}/rest/v1/rpc/dashboard_authorized`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      apikey: String(env.SUPABASE_PUBLISHABLE_KEY),
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: "{}",
  });
  if (!response.ok) {
    if (response.status === 401) throw new HttpError(401, "Your Supabase login expired. Sign in again.");
    if (response.status === 403 || response.status === 404) throw new HttpError(403, "This Supabase user is not authorized for Ricochet reporting.");
    throw new HttpError(502, "The bridge could not verify report access with Supabase.");
  }
  const authorized = await response.json().catch(() => false);
  if (authorized !== true) throw new HttpError(403, "This Supabase user is not authorized for Ricochet reporting.");
}

function recordingId(pathname, suffix) {
  const prefix = "/recordings/";
  const raw = pathname.slice(prefix.length, -suffix.length).replace(/\/$/, "");
  let id;
  try { id = decodeURIComponent(raw).trim(); } catch { throw new HttpError(400, "Invalid recording identifier."); }
  if (!RECORDING_ID.test(id)) throw new HttpError(400, "A valid recording identifier is required.");
  return id;
}

async function boundedJsonBody(request) {
  const declared = Number(request.headers.get("content-length") || 0);
  if (declared > MAX_JSON_BYTES) throw new HttpError(413, "AI request is too large.");
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_JSON_BYTES) throw new HttpError(413, "AI request is too large.");
  if (!text) return {};
  let parsed;
  try { parsed = JSON.parse(text); } catch { throw new HttpError(400, "AI request must be valid JSON."); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new HttpError(400, "AI request must be a JSON object.");
  return parsed;
}

function upstreamHeaders(request, env, contentType = false) {
  const headers = new Headers({
    accept: request.headers.get("accept") || "application/json",
    "x-report-key": String(env.PRIVATE_WORKER_API_KEY),
  });
  if (contentType) headers.set("content-type", "application/json");
  for (const name of ["range", "if-range", "if-none-match", "if-modified-since", "x-correlation-id"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

async function proxyRecording(request, env, pathname, url) {
  const isParts = pathname.endsWith("/parts");
  const suffix = isParts ? "/parts" : "/audio";
  const id = recordingId(pathname, suffix);
  const upstreamPath = isParts ? `/api/recording-parts/${encodeURIComponent(id)}` : `/api/recording-audio/${encodeURIComponent(id)}`;
  const upstreamUrl = new URL(`https://ricochet-private.internal${upstreamPath}`);
  upstreamUrl.search = url.search;
  const upstream = await env.PRIVATE_D1_WORKER.fetch(new Request(upstreamUrl, {
    method: request.method,
    headers: upstreamHeaders(request, env),
  }));
  const headers = responseHeaders(request, env);
  for (const name of ["content-type", "content-length", "content-range", "accept-ranges", "etag", "last-modified", "x-recording-parts", "x-recording-part"]) {
    const value = upstream.headers.get(name); if (value) headers.set(name, value);
  }
  if (isParts && !headers.has("content-type")) headers.set("content-type", "application/json; charset=utf-8");
  return new Response(request.method === "HEAD" ? null : upstream.body, { status: upstream.status, statusText: upstream.statusText, headers });
}

const AI_ROUTES = Object.freeze(new Map([
  ["/ai/analyze-call", "/admin/analyze-call"],
  ["/ai/transcribe-call", "/admin/transcribe-call"],
  ["/ai/queue-calls", "/admin/queue-ai-calls"],
  ["/ai/queue-contact-verification", "/admin/queue-contact-verification"],
  ["/ai/teacher/run", "/admin/ai-teacher/run"],
  ["/ai/teacher/decision", "/admin/ai-teacher/decision"],
  ["/ai/teacher/example", "/admin/ai-teacher/example-toggle"],
  ["/ai/teacher/rule", "/admin/ai-teacher/rule-toggle"],
  ["/ai/feedback", "/admin/ai-feedback"],
  ["/ai/guidance", "/admin/ai-guidance"],
]));

async function proxyAi(request, env, pathname, ctx) {
  if (request.method !== "POST") throw new HttpError(405, "AI actions require POST.");
  const upstreamPath = AI_ROUTES.get(pathname);
  if (!upstreamPath) throw new HttpError(404, "AI action not found.");
  const body = await boundedJsonBody(request);
  const upstreamUrl = new URL(`https://ricochet-private.internal${upstreamPath}`);
  if (["/ai/analyze-call", "/ai/transcribe-call"].includes(pathname)) {
    const callEventId = Number(body.call_event_id || body.callEventId || 0);
    if (!Number.isInteger(callEventId) || callEventId <= 0) throw new HttpError(400, "A valid call_event_id is required.");
    upstreamUrl.searchParams.set("call_event_id", String(callEventId));
  }
  const upstream = await env.PRIVATE_D1_WORKER.fetch(new Request(upstreamUrl, {
    method: "POST",
    headers: upstreamHeaders(request, env, true),
    body: JSON.stringify(body),
  }));
  if (upstream.ok && env.SUPABASE_SYNC_QUEUE?.send) {
    ctx.waitUntil(env.SUPABASE_SYNC_QUEUE.send({ kind: "operational-refresh", requestedAt: new Date().toISOString() }).catch(() => undefined));
  }
  const headers = responseHeaders(request, env);
  headers.set("content-type", upstream.headers.get("content-type") || "application/json; charset=utf-8");
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers });
}

async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const pathname = url.pathname.replace(/\/+$/, "") || "/";
  if (request.method === "OPTIONS") {
    if (request.headers.get("origin") && !allowedOrigin(request, env)) throw new HttpError(403, "Origin is not allowed.");
    return new Response(null, { status: 204, headers: responseHeaders(request, env) });
  }
  if (request.method === "GET" && pathname === "/health") return json(request, env, { success: true, service: "ricochet-private-report-bridge", timestamp: new Date().toISOString() });
  requireEnvironment(env);
  if (request.headers.get("origin") && !allowedOrigin(request, env)) throw new HttpError(403, "Origin is not allowed.");
  await verifyReportUser(request, env);
  if (pathname.startsWith("/recordings/") && (pathname.endsWith("/parts") || pathname.endsWith("/audio"))) return proxyRecording(request, env, pathname, url);
  if (pathname.startsWith("/ai/")) return proxyAi(request, env, pathname, ctx);
  throw new HttpError(404, "Endpoint not found.");
}

export default {
  async fetch(request, env, ctx) {
    try { return await handle(request, env, ctx); }
    catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      if (status >= 500) console.error(JSON.stringify({ event: "bridge_error", status, message: String(error?.message || error) }));
      return json(request, env, { success: false, error: status === 500 ? "The private bridge could not complete the request." : error.message }, status);
    }
  },
};

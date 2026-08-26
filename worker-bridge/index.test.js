import assert from "node:assert/strict";
import test from "node:test";
import worker from "./index.js";

function environment(handler) {
  return {
    SUPABASE_URL: "https://project.supabase.co",
    SUPABASE_PUBLISHABLE_KEY: "publishable",
    ALLOWED_ORIGINS: "https://example.github.io,http://localhost:*",
    PRIVATE_WORKER_API_KEY: "private-secret",
    PRIVATE_D1_WORKER: { fetch: handler },
  };
}

const context = { waitUntil() {} };

test("health is public and contains no configuration", async () => {
  const response = await worker.fetch(new Request("https://bridge.test/health"), {}, context);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).service, "ricochet-private-report-bridge");
});

test("unknown browser origins are rejected", async () => {
  const response = await worker.fetch(new Request("https://bridge.test/recordings/call-0001/parts", {
    headers: { origin: "https://attacker.example", authorization: "Bearer user-token" },
  }), environment(() => new Response("{}")), context);
  assert.equal(response.status, 403);
});

test("recording metadata is authorized and proxied without exposing the private key", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    assert.match(String(input), /dashboard_authorized$/);
    assert.equal(init.headers.authorization, "Bearer user-token");
    return Response.json(true);
  };
  let upstream;
  const env = environment((request) => {
    upstream = request;
    return Response.json({ success: true, parts: 2 });
  });
  const response = await worker.fetch(new Request("https://bridge.test/recordings/call-0001/parts", {
    headers: { origin: "https://example.github.io", authorization: "Bearer user-token" },
  }), env, context);
  globalThis.fetch = originalFetch;
  assert.equal(response.status, 200);
  assert.equal(new URL(upstream.url).pathname, "/api/recording-parts/call-0001");
  assert.equal(upstream.headers.get("x-report-key"), "private-secret");
  assert.equal(response.headers.get("access-control-allow-origin"), "https://example.github.io");
  assert.equal(response.headers.get("x-report-key"), null);
});

test("AI routes accept bounded JSON and only proxy allowlisted actions", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => Response.json(true);
  let upstream;
  const response = await worker.fetch(new Request("https://bridge.test/ai/analyze-call", {
    method: "POST",
    headers: { origin: "http://localhost:5173", authorization: "Bearer user-token", "content-type": "application/json" },
    body: JSON.stringify({ call_event_id: 42 }),
  }), environment((request) => { upstream = request; return Response.json({ success: true, queued: true }); }), context);
  globalThis.fetch = originalFetch;
  assert.equal(response.status, 200);
  assert.equal(new URL(upstream.url).pathname, "/admin/analyze-call");
  assert.equal(new URL(upstream.url).searchParams.get("call_event_id"), "42");
  assert.deepEqual(await upstream.json(), { call_event_id: 42 });
});

/**
 * @agents-index Unit tests for health.alloy: verifies the collector probe returns
 *   true on 2xx, false on non-2xx, false when unreachable, and false on timeout.
 *
 * Why: the probe gates the dynamic-default-enabled decision; these tests lock its
 * fail-safe "absent means off" behaviour so pi never emits into a dead endpoint
 * and never hangs startup waiting on a stalled collector.
 */

import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { test } from "node:test";

import { DEFAULT_ALLOY_HEALTH_URL, probeAlloyHealthy } from "./health.alloy.ts";

test("default-health-url-proxied", () => {
  // Alloy is no longer published on :12345; the default health probe must target
  // the proxied /alloy/-/healthy path on the single HAProxy port.
  assert.equal(DEFAULT_ALLOY_HEALTH_URL, "http://localhost:24317/alloy/-/healthy");
});

/** Start a localhost HTTP server with a given handler; resolve its base URL. */
function startServer(
  handler: (respond: (status: number) => void, delayMs: number) => void,
): Promise<{ url: string; server: Server }> {
  return new Promise((resolve) => {
    const server = createServer((_req, res) => {
      handler((status) => {
        res.statusCode = status;
        res.end("ok");
      }, 0);
    });
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      resolve({ url: `http://127.0.0.1:${port}/-/healthy`, server });
    });
  });
}

test("healthy-on-200", async () => {
  const { url, server } = await startServer((respond) => respond(200));
  try {
    assert.equal(await probeAlloyHealthy(url), true);
  } finally {
    server.close();
  }
});

test("unhealthy-on-500", async () => {
  const { url, server } = await startServer((respond) => respond(500));
  try {
    assert.equal(await probeAlloyHealthy(url), false);
  } finally {
    server.close();
  }
});

test("unhealthy-when-unreachable", async () => {
  // Port 1 is not listening; connection is refused immediately.
  assert.equal(await probeAlloyHealthy("http://127.0.0.1:1/-/healthy"), false);
});

test("unhealthy-on-timeout", async () => {
  const server = createServer((_req, res) => {
    // Never respond within the probe window.
    setTimeout(() => res.end("late"), 1000).unref();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const addr = server.address();
  const port = typeof addr === "object" && addr ? addr.port : 0;
  try {
    assert.equal(await probeAlloyHealthy(`http://127.0.0.1:${port}/-/healthy`, 50), false);
  } finally {
    server.close();
  }
});

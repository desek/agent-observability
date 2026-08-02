/**
 * @agents-index Unit test for the MLflow exporter: pins that every export carries
 *   the x-mlflow-experiment-id header, that configured extra headers ride
 *   alongside it, that an unreachable or throwing server produces no throw and no
 *   retry, and that a pending export is flushed on shutdown so the last
 *   conversation is not lost.
 *
 * Why: the exporter is the one place conversation content leaves the process, so
 * its contract with MLflow (the experiment header) and its safety guarantees
 * (silent on failure, flush on shutdown) are load-bearing (FR8, FR10, FR16, NFR4,
 * AC-11, AC-16). These tests drive it with a fake fetch so the wire contract and
 * the lifecycle are pinned without a live tracking server.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { EXPERIMENT_HEADER, MlflowExporter, type FetchLike } from "./mlflow.exporter.ts";
import type { BuiltTrace } from "./trace.builder.ts";

/** A minimal completed trace: one root AGENT span with the reserved attributes. */
function fakeTrace(): BuiltTrace {
  return {
    sessionId: "sess-1",
    root: {
      name: "agent",
      type: "AGENT",
      attributes: {
        "mlflow.spanType": JSON.stringify("AGENT"),
        "mlflow.spanInputs": JSON.stringify("hello"),
        "mlflow.spanOutputs": JSON.stringify("hi"),
        "session.id": "sess-1",
      },
      children: [],
    },
  };
}

/** A fake fetch that records every call and answers 200. */
function recordingFetch() {
  const calls: Array<{ url: string; headers: Record<string, string>; body: string }> = [];
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push({ url, headers: init.headers, body: init.body });
    return { ok: true, status: 200 };
  };
  return { fetchImpl, calls };
}

test("sends the experiment header", async () => {
  // Every export must carry the resolved experiment id in the required header (FR8).
  const { fetchImpl, calls } = recordingFetch();
  const exporter = new MlflowExporter(
    { endpoint: "http://localhost:1/v1/traces", experimentId: "42", headers: {} },
    fetchImpl,
  );
  exporter.export(fakeTrace());
  await exporter.flush();

  assert.equal(calls.length, 1, "one export makes one request");
  assert.equal(calls[0].headers[EXPERIMENT_HEADER], "42", "the experiment id rides in the header");
  assert.match(calls[0].body, /resourceSpans/, "the body is an OTLP trace export");
});

test("sends the configured extra headers", async () => {
  // User-supplied headers accompany the experiment header (FR10).
  const { fetchImpl, calls } = recordingFetch();
  const exporter = new MlflowExporter(
    {
      endpoint: "http://localhost:1/v1/traces",
      experimentId: "7",
      headers: { authorization: "Bearer abc" },
    },
    fetchImpl,
  );
  exporter.export(fakeTrace());
  await exporter.flush();

  assert.equal(calls[0].headers.authorization, "Bearer abc", "the configured header is present");
  assert.equal(calls[0].headers[EXPERIMENT_HEADER], "7", "the experiment header is still present");
});

test("silent when the server is absent", async () => {
  // A refused connection produces no throw and no retry: exactly one attempt, and
  // the failure is swallowed (FR16, NFR1, AC-11).
  let attempts = 0;
  const fetchImpl: FetchLike = async () => {
    attempts += 1;
    throw new Error("ECONNREFUSED");
  };
  const exporter = new MlflowExporter(
    { endpoint: "http://localhost:1/v1/traces", experimentId: "1", headers: {} },
    fetchImpl,
  );
  // export must not throw synchronously, and flush must resolve rather than reject.
  exporter.export(fakeTrace());
  await assert.doesNotReject(() => exporter.flush(), "flush never rejects on a failed export");
  assert.equal(attempts, 1, "an unreachable server is tried once, with no retry storm");
});

test("flushes pending exports on shutdown", async () => {
  // A pending export is awaited by flush, so the last conversation of a session is
  // delivered before the process exits (NFR4, AC-16). The fake fetch resolves only
  // when released, so a flush that returned early would be observable.
  let release: () => void = () => {};
  let settled = false;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const fetchImpl: FetchLike = async () => {
    await gate;
    settled = true;
    return { ok: true, status: 200 };
  };
  const exporter = new MlflowExporter(
    { endpoint: "http://localhost:1/v1/traces", experimentId: "1", headers: {} },
    fetchImpl,
  );
  exporter.export(fakeTrace());

  const flushed = exporter.flush();
  assert.equal(settled, false, "the export is still in flight before it is released");
  release();
  await flushed;
  assert.equal(settled, true, "flush waited for the pending export to complete");
});

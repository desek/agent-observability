/**
 * @agents-index Unit test for the index factory: verifies the master switch keeps
 *   the extension silent when disabled, that a throwing lifecycle handler is caught
 *   (fail-safe, NFR2), and that the flush handlers (agent_end, session_shutdown)
 *   are registered when enabled (NFR5).
 *
 * Why: the factory is pi's entry point; a telemetry fault must never crash or block
 * the agent loop and buffered signals must be flushable on teardown. This test
 * drives the factory with a fake ExtensionAPI so both guarantees are pinned without
 * a live collector.
 */

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import factory from "./index.ts";

/** A fake ExtensionAPI that records registered handlers by event name. */
function makeFakePi() {
  const handlers = new Map<string, Array<(e: unknown, c: unknown) => unknown>>();
  const pi = {
    on(event: string, handler: (e: unknown, c: unknown) => unknown) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
  };
  return { pi: pi as never, handlers };
}

const ENV_KEYS = ["PI_OTEL_ENABLE", "OTEL_METRICS_EXPORTER", "OTEL_LOGS_EXPORTER", "OTEL_TRACES_EXPORTER"];
const saved: Record<string, string | undefined> = {};
for (const k of ENV_KEYS) saved[k] = process.env[k];

afterEach(() => {
  for (const k of ENV_KEYS) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k];
  }
});

test("handler-failsafe-and-flush", async () => {
  // Explicit master switch off: no probe, no handlers, nothing emitted (AC-11).
  process.env.PI_OTEL_ENABLE = "0";
  const disabled = makeFakePi();
  await factory(disabled.pi);
  assert.equal(disabled.handlers.size, 0, "disabled factory registers no handlers");

  // Explicit on: async factory awaited; providers initialize and lifecycle +
  // flush handlers are registered. Explicit on skips the health probe.
  process.env.PI_OTEL_ENABLE = "1";
  const enabled = makeFakePi();
  await factory(enabled.pi);
  assert.ok(enabled.handlers.has("agent_end"), "agent_end flush registered");
  assert.ok(enabled.handlers.has("session_shutdown"), "session_shutdown flush registered");
  assert.ok(enabled.handlers.has("session_start"), "lifecycle handler registered");

  // A malformed event handed to a handler must be swallowed, never thrown (NFR2).
  const sessionStart = enabled.handlers.get("session_start")![0];
  assert.doesNotThrow(() => sessionStart(undefined, {}));
  const messageEnd = enabled.handlers.get("message_end")![0];
  assert.doesNotThrow(() => messageEnd(undefined, {}));
});

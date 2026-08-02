/**
 * @agents-index Unit test for the index factory: verifies the master switch keeps
 *   the extension silent when disabled (no handler registered), and that a
 *   throwing host API is swallowed so a fault never propagates into pi
 *   (fail-safe, NFR1).
 *
 * Why: the factory is pi's entry point and the one place that writes conversation
 * content, so its two load-bearing guarantees are off-by-default and never-crash.
 * This test drives the factory with a fake ExtensionAPI so both are pinned
 * without a live tracking server (AC-2, AC-15).
 */

import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import factory, { ENABLE_ENV } from "./index.ts";

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

/** A fake ExtensionAPI whose `on` throws on every call, standing in for a host
 * whose registration path faults. */
function makeThrowingPi() {
  const pi = {
    on() {
      throw new Error("host API is broken");
    },
  };
  return pi as never;
}

const saved = process.env[ENABLE_ENV];

afterEach(() => {
  if (saved === undefined) delete process.env[ENABLE_ENV];
  else process.env[ENABLE_ENV] = saved;
});

test("registers nothing when disabled", async () => {
  // Master switch unset: no handler, no exporter, no socket (AC-2).
  delete process.env[ENABLE_ENV];
  const unset = makeFakePi();
  await factory(unset.pi);
  assert.equal(unset.handlers.size, 0, "an unset switch registers no handler");

  // An explicit false value is equally a no-op.
  process.env[ENABLE_ENV] = "0";
  const off = makeFakePi();
  await factory(off.pi);
  assert.equal(off.handlers.size, 0, "a false switch registers no handler");
});

test("a handler error never propagates", async () => {
  // Enabled, but the host API throws on every registration. The factory must
  // resolve without raising, so a telemetry fault can never crash pi (NFR1).
  process.env[ENABLE_ENV] = "1";
  await assert.doesNotReject(() => factory(makeThrowingPi()));
});

/**
 * @agents-index Unit test for attributes.standard: verifies the
 *   OTEL_METRICS_INCLUDE_* cardinality gates include a dimension only when both the
 *   flag is enabled and a value is supplied.
 *
 * Why: cardinality gating is the parity control that trades detail for series
 * count (FR10, AC-10); this test pins the "flag on AND value present" semantics so
 * high-cardinality attributes cannot leak onto metrics when their flag is off.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildStandardAttributes } from "./attributes.standard.ts";
import { loadConfig } from "./config.env.ts";

test("cardinality-gates", () => {
  const ctx = {
    sessionId: "sess-1",
    version: "0.1.0",
    accountUuid: "uuid-1",
    entrypoint: "cli",
  };

  // All flags off (unset): no gated dimension is attached even with values present.
  const off = buildStandardAttributes(loadConfig({}), ctx);
  assert.equal(off["session.id"], undefined);
  assert.equal(off["app.version"], undefined);
  assert.equal(off["user.account_uuid"], undefined);
  assert.equal(off["entrypoint"], undefined);

  // Flags on: dimensions with a supplied value are attached; resource attributes
  // are promoted when their flag is on.
  const on = buildStandardAttributes(
    loadConfig({
      OTEL_METRICS_INCLUDE_SESSION_ID: "1",
      OTEL_METRICS_INCLUDE_VERSION: "1",
      OTEL_METRICS_INCLUDE_ACCOUNT_UUID: "1",
      OTEL_METRICS_INCLUDE_ENTRYPOINT: "1",
      OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES: "1",
      OTEL_RESOURCE_ATTRIBUTES: "git.branch=dev/otel",
    }),
    ctx,
  );
  assert.equal(on["session.id"], "sess-1");
  assert.equal(on["app.version"], "0.1.0");
  assert.equal(on["user.account_uuid"], "uuid-1");
  assert.equal(on["entrypoint"], "cli");
  assert.equal(on["git.branch"], "dev/otel");

  // Flag on but value absent: dimension stays off.
  const noValue = buildStandardAttributes(
    loadConfig({ OTEL_METRICS_INCLUDE_SESSION_ID: "1" }),
    {},
  );
  assert.equal(noValue["session.id"], undefined);
});

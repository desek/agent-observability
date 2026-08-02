/**
 * @agents-index Unit tests for config.env: verifies the gRPC localhost:24317
 *   (HAProxy edge-proxy port) defaults, the PI_OTEL_ENABLE master switch, and
 *   that the standard OTEL_*
 *   exporter/interval/resource variables are parsed into the typed config.
 *
 * Why: config parsing is the single source of truth for every downstream signal
 * (FR4, FR5, FR11); these tests lock the Claude-Code-parity defaults and opt-in
 * semantics so a regression in parsing cannot silently redirect or disable export.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DEFAULT_OTLP_ENDPOINT,
  DEFAULT_OTLP_PROTOCOL,
  loadConfig,
  parseEnableSetting,
  resolveEnabled,
} from "./config.env.ts";

/** Probe stub recording whether it was called, returning a fixed health value. */
function stubProbe(healthy: boolean) {
  const calls = { count: 0 };
  const probe = async () => {
    calls.count += 1;
    return healthy;
  };
  return { probe, calls };
}

test("defaults-to-grpc-single-port", () => {
  const config = loadConfig({});
  assert.equal(config.exporters.metrics.protocol, DEFAULT_OTLP_PROTOCOL);
  assert.equal(config.exporters.metrics.protocol, "grpc");
  assert.equal(config.exporters.logs.endpoint, DEFAULT_OTLP_ENDPOINT);
  assert.equal(config.exporters.traces.endpoint, "http://localhost:24317");
  assert.equal(config.serviceName, "pi-coding-agent");
});

test("master-switch-disables", () => {
  assert.equal(loadConfig({}).enabled, false);
  assert.equal(loadConfig({ PI_OTEL_ENABLE: "0" }).enabled, false);
  assert.equal(loadConfig({ PI_OTEL_ENABLE: "false" }).enabled, false);
  assert.equal(loadConfig({ PI_OTEL_ENABLE: "1" }).enabled, true);
  assert.equal(loadConfig({ PI_OTEL_ENABLE: "true" }).enabled, true);
});

test("parse-enable-setting-tri-state", () => {
  assert.equal(parseEnableSetting(undefined), "unset");
  assert.equal(parseEnableSetting(""), "unset");
  assert.equal(parseEnableSetting("1"), "on");
  assert.equal(parseEnableSetting("true"), "on");
  assert.equal(parseEnableSetting("0"), "off");
  assert.equal(parseEnableSetting("false"), "off");
});

test("resolve-enabled-explicit-on-skips-probe", async () => {
  const { probe, calls } = stubProbe(false);
  assert.equal(await resolveEnabled(loadConfig({ PI_OTEL_ENABLE: "1" }), probe), true);
  assert.equal(calls.count, 0);
});

test("resolve-enabled-explicit-off-skips-probe", async () => {
  const { probe, calls } = stubProbe(true);
  assert.equal(await resolveEnabled(loadConfig({ PI_OTEL_ENABLE: "0" }), probe), false);
  assert.equal(calls.count, 0);
});

test("resolve-enabled-unset-with-endpoint-enables-without-probe", async () => {
  const { probe, calls } = stubProbe(false);
  const config = loadConfig({ OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4317" });
  assert.equal(await resolveEnabled(config, probe), true);
  assert.equal(calls.count, 0);
});

test("resolve-enabled-dynamic-follows-health-probe", async () => {
  const healthy = stubProbe(true);
  assert.equal(await resolveEnabled(loadConfig({}), healthy.probe), true);
  assert.equal(healthy.calls.count, 1);

  const down = stubProbe(false);
  assert.equal(await resolveEnabled(loadConfig({}), down.probe), false);
  assert.equal(down.calls.count, 1);
});

test("honors-standard-otel-vars", () => {
  const config = loadConfig({
    PI_OTEL_ENABLE: "1",
    OTEL_SERVICE_NAME: "custom-service",
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4317",
    OTEL_METRIC_EXPORT_INTERVAL: "5000",
    OTEL_LOGS_EXPORTER: "none",
    OTEL_RESOURCE_ATTRIBUTES: "git.branch=dev/otel,git.repo=demo",
    OTEL_LOG_USER_PROMPTS: "1",
    OTEL_METRICS_INCLUDE_SESSION_ID: "1",
  });
  assert.equal(config.serviceName, "custom-service");
  assert.equal(config.exporters.metrics.endpoint, "http://collector:4317");
  assert.equal(config.exporters.metrics.exportIntervalMillis, 5000);
  assert.equal(config.selection.logs, "none");
  assert.equal(config.selection.metrics, "otlp");
  assert.equal(config.resourceAttributes["git.branch"], "dev/otel");
  assert.equal(config.content.userPrompts, true);
  assert.equal(config.content.assistantResponses, false);
  assert.equal(config.cardinality.sessionId, true);
});

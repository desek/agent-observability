/**
 * @agents-index Unit tests for otel.providers and the package manifest: verifies
 *   the shared Resource defaults service.name to pi-coding-agent and honours
 *   OTEL_SERVICE_NAME, and that package.json declares the nine pinned OTLP-gRPC
 *   OpenTelemetry dependencies.
 *
 * Why: the Resource carries the identity every signal is grouped by (FR3) and the
 * pinned gRPC exporter deps make the build reproducible (FR2, NFR3); these tests
 * pin both so a rename or a dropped dependency is caught before it reaches a run.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { loadConfig } from "./config.env.ts";
import { buildResource } from "./otel.providers.ts";

test("resource-service-name", () => {
  const dflt = buildResource(loadConfig({}));
  assert.equal(dflt.attributes["service.name"], "pi-coding-agent");

  const overridden = buildResource(
    loadConfig({ OTEL_SERVICE_NAME: "pi-custom" }),
  );
  assert.equal(overridden.attributes["service.name"], "pi-custom");
});

test("declares-grpc-exporter-deps", () => {
  const pkgPath = fileURLToPath(new URL("../package.json", import.meta.url));
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as {
    dependencies: Record<string, string>;
  };
  const required = [
    "@opentelemetry/api",
    "@opentelemetry/api-logs",
    "@opentelemetry/resources",
    "@opentelemetry/sdk-metrics",
    "@opentelemetry/sdk-logs",
    "@opentelemetry/sdk-trace-base",
    "@opentelemetry/exporter-metrics-otlp-grpc",
    "@opentelemetry/exporter-logs-otlp-grpc",
    "@opentelemetry/exporter-trace-otlp-grpc",
  ];
  for (const dep of required) {
    assert.ok(pkg.dependencies[dep], `missing dependency ${dep}`);
    // Pinned to an exact version (no range specifier) for reproducibility.
    assert.match(pkg.dependencies[dep], /^\d+\.\d+\.\d+$/, `${dep} not pinned`);
  }
});

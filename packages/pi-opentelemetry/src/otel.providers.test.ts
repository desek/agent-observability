/**
 * @agents-index Unit tests for otel.providers and the package manifest: verifies
 *   the shared Resource defaults service.name to pi-coding-agent and honours
 *   OTEL_SERVICE_NAME, and that package.json declares the eight OTLP-gRPC SDK and
 *   exporter dependencies while the OpenTelemetry API is a peer dependency.
 *
 * Why: the Resource carries the identity every signal is grouped by (FR3) and the
 * SDK/exporter deps make the build reproducible (FR2, NFR3); the API is a peer so
 * a second copy in the host process cannot silently break instrumentation
 * registration (FR11). These tests catch a rename, a dropped dependency, or a
 * regression that reintroduces the API as an ordinary dependency.
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
    peerDependencies: Record<string, string>;
  };
  // The SDK and exporter packages stay ordinary dependencies, with tilde ranges
  // that admit patch updates so a security fix needs no release of this package.
  const required = [
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
    // A tilde-pinned patch range (~x.y.z) for reproducibility with patch updates.
    assert.match(pkg.dependencies[dep], /^~\d+\.\d+\.\d+$/, `${dep} not tilde-pinned`);
  }
  // The API package is a peer, never an ordinary dependency: two copies in one
  // process silently break instrumentation registration (FR11).
  assert.ok(
    pkg.peerDependencies["@opentelemetry/api"],
    "@opentelemetry/api must be a peer dependency",
  );
  assert.equal(
    pkg.dependencies["@opentelemetry/api"],
    undefined,
    "@opentelemetry/api must not also be an ordinary dependency",
  );
});

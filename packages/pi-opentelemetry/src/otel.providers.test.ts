/**
 * @agents-index Unit tests for otel.providers and the package manifest: verifies
 *   the shared Resource defaults service.name to pi-coding-agent and honours
 *   OTEL_SERVICE_NAME, that resolveTransport maps each OTLP protocol value to a
 *   supported transport or rejects it, and that package.json declares the OTLP
 *   gRPC and HTTP SDK and exporter dependencies while the OpenTelemetry API is a
 *   peer dependency.
 *
 * Why: the Resource carries the identity every signal is grouped by (FR3), the
 * transport mapping decides which exporter a signal's protocol selects (and that
 * an unsupported value is rejected rather than silently sent over gRPC), and the
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
import { buildResource, resolveTransport, SUPPORTED_OTLP_PROTOCOLS } from "./otel.providers.ts";

test("resource-service-name", () => {
  const dflt = buildResource(loadConfig({}));
  assert.equal(dflt.attributes["service.name"], "pi-coding-agent");

  const overridden = buildResource(
    loadConfig({ OTEL_SERVICE_NAME: "pi-custom" }),
  );
  assert.equal(overridden.attributes["service.name"], "pi-custom");
});

test("resolve-transport-maps-supported-and-rejects-unsupported", () => {
  // grpc and the unset/blank case keep today's transport; http/protobuf selects
  // HTTP; the match is case-insensitive and trimmed.
  assert.equal(resolveTransport("grpc"), "grpc");
  assert.equal(resolveTransport(""), "grpc");
  assert.equal(resolveTransport("  GRPC "), "grpc");
  assert.equal(resolveTransport("http/protobuf"), "http/protobuf");
  assert.equal(resolveTransport("HTTP/PROTOBUF"), "http/protobuf");

  // Anything else is rejected (undefined) rather than silently treated as gRPC,
  // including the JSON variant the Node SDK ships no exporter for.
  assert.equal(resolveTransport("http/json"), undefined);
  assert.equal(resolveTransport("nonsense"), undefined);

  // The supported set is exactly the two transports the mapping accepts.
  assert.deepEqual([...SUPPORTED_OTLP_PROTOCOLS], ["grpc", "http/protobuf"]);
});

test("declares-grpc-and-http-exporter-deps", () => {
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
    // The HTTP/protobuf exporter siblings, so OTEL_EXPORTER_OTLP_PROTOCOL can
    // select HTTP for any signal (this defect fix).
    "@opentelemetry/exporter-metrics-otlp-http",
    "@opentelemetry/exporter-logs-otlp-http",
    "@opentelemetry/exporter-trace-otlp-http",
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

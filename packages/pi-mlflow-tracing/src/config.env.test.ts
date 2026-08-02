/**
 * @agents-index Unit test for the configuration parser: pins that the master
 *   switch and endpoint are read from the environment, that the switch is off when
 *   unset, that every default resolves to the local stack built from the edge port
 *   (never a hard-coded literal), that configured values win over defaults, that a
 *   malformed endpoint is rejected with a message naming the value and the form,
 *   and that a non-loopback destination is flagged.
 *
 * Why: this module is the single decision of where conversation content goes, so
 * every load-bearing rule (off-by-default, local default from the edge port, config
 * wins, malformed rejected, remote flagged) is pinned here against a supplied
 * environment map with no process state and no network (FR9, FR10, FR11, FR12,
 * FR13, AC-6, AC-7, AC-8, AC-9).
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DEFAULT_EXPERIMENT,
  ENABLE_ENV,
  ENDPOINT_ENV,
  EXPERIMENT_ENV,
  HEADERS_ENV,
  TRACKING_ENV,
  loadConfig,
} from "./config.env.ts";

test("reads the switch and the endpoint", () => {
  // The switch and the endpoint come straight from the environment; the endpoint
  // is honoured as configured, and the edge port is not consulted for it.
  const cfg = loadConfig({
    [ENABLE_ENV]: "1",
    [ENDPOINT_ENV]: "http://localhost:9999/mlflow-otlp/v1/traces",
  });
  assert.equal(cfg.enabled, true, "the switch is read as enabled");
  assert.equal(
    cfg.endpoint,
    "http://localhost:9999/mlflow-otlp/v1/traces",
    "the configured endpoint is read from the environment",
  );
  assert.equal(cfg.endpointExplicit, true, "a configured endpoint is marked explicit");
});

test("disabled without the switch", () => {
  // An empty environment is off: the extension must be a hard no-op (AC-2).
  const cfg = loadConfig({});
  assert.equal(cfg.enabled, false, "an unset switch is disabled");
});

test("defaults resolve to the local stack", () => {
  // With only the switch and the edge port set, the endpoint and the tracking
  // address are built from the edge port and the experiment defaults to `pi`
  // (FR11, AC-6). The edge port used here is deliberately not the project default.
  const port = "24417";
  const cfg = loadConfig({ [ENABLE_ENV]: "1", EDGE_PORT: port });
  assert.equal(
    cfg.endpoint,
    `http://localhost:${port}/mlflow-otlp/v1/traces`,
    "the ingest endpoint is built from the edge port",
  );
  assert.equal(
    cfg.trackingUri,
    `http://localhost:${port}/mlflow`,
    "the tracking address is built from the edge port",
  );
  assert.equal(cfg.experiment, DEFAULT_EXPERIMENT, "the experiment defaults to pi");
  assert.equal(cfg.experiment, "pi", "the default experiment name is pi");
  assert.equal(cfg.endpointExplicit, false, "a derived endpoint is not explicit");
  assert.equal(cfg.remoteHost, undefined, "a loopback default is not flagged remote");
});

test("no source file hard-codes the default port", () => {
  // FR11 is a source-level invariant: the default port must never appear as a
  // literal destination in a source file. Read the module sources and assert the
  // project default port is absent, so the default always follows EDGE_PORT.
  const files = ["config.env.ts", "mlflow.exporter.ts", "mlflow.experiment.ts", "index.ts"];
  for (const file of files) {
    const source = readSource(file);
    assert.ok(
      !/\b24317\b/.test(source),
      `${file} must not contain the default edge port 24317 as a literal (FR11)`,
    );
  }
});

test("configured values override the defaults", () => {
  // A fully configured environment: endpoint, tracking address, experiment, and an
  // extra header all win over the local defaults (FR10, AC-7). The edge port is set
  // too, to prove the configured values win rather than the derived ones.
  const cfg = loadConfig({
    [ENABLE_ENV]: "1",
    EDGE_PORT: "24417",
    [ENDPOINT_ENV]: "https://mlflow.example.com/otlp/v1/traces",
    [TRACKING_ENV]: "https://mlflow.example.com/",
    [EXPERIMENT_ENV]: "pi-prod",
    [HEADERS_ENV]: "authorization=Bearer abc,x-team=platform",
  });
  assert.equal(
    cfg.endpoint,
    "https://mlflow.example.com/otlp/v1/traces",
    "the configured endpoint wins over the derived default",
  );
  assert.equal(
    cfg.trackingUri,
    "https://mlflow.example.com",
    "the configured tracking address wins and its trailing slash is trimmed",
  );
  assert.equal(cfg.experiment, "pi-prod", "the configured experiment name wins");
  assert.deepEqual(
    cfg.headers,
    { authorization: "Bearer abc", "x-team": "platform" },
    "the configured extra headers are parsed",
  );
});

test("a malformed endpoint is rejected", () => {
  // An endpoint that is not an absolute URL disables export and states the value
  // rejected and the form expected (FR13, AC-9).
  const cfg = loadConfig({ [ENABLE_ENV]: "1", EDGE_PORT: "24417", [ENDPOINT_ENV]: "not-a-url" });
  assert.equal(cfg.endpoint, undefined, "a malformed endpoint leaves no endpoint to export to");
  assert.ok(cfg.rejection, "a malformed endpoint produces a rejection message");
  assert.match(cfg.rejection!, /not-a-url/, "the message names the value it rejected");
  assert.match(cfg.rejection!, /absolute URL/i, "the message names the form it expects");
});

test("a non-loopback destination is flagged", () => {
  // A destination on a remote host is marked so the extension can state it once at
  // session start (FR12, NFR5, AC-8).
  const cfg = loadConfig({
    [ENABLE_ENV]: "1",
    [ENDPOINT_ENV]: "http://mlflow.internal.example.com:5000/v1/traces",
  });
  assert.equal(
    cfg.remoteHost,
    "mlflow.internal.example.com",
    "a non-loopback host is captured so it can be disclosed",
  );

  // 127.0.0.1 and ::1 are loopback and are not flagged.
  const local = loadConfig({ [ENABLE_ENV]: "1", [ENDPOINT_ENV]: "http://127.0.0.1:5000/v1/traces" });
  assert.equal(local.remoteHost, undefined, "127.0.0.1 is loopback and not flagged");
});

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Read one of this package's source files as text, resolved relative to this test
 * file so the FR11 literal-port check runs from any working directory.
 *
 * @param file - The source file basename.
 * @returns The file contents.
 */
function readSource(file: string): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return readFileSync(join(here, file), "utf8");
}

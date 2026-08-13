/**
 * @agents-index Unit tests for config.file: verifies the observability.json file
 *   is read at global and project scope, project overrides global, the process
 *   environment wins over the file, malformed or non-object files degrade to no
 *   config, and non-scalar values are dropped.
 *
 * Why: the config file is a second configuration source layered under the
 * environment; these tests lock the precedence contract (env over file, project
 * over global) and the fail-safe posture so a broken file can never crash pi or
 * silently override an explicit environment variable.
 */

import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";

import { CONFIG_FILE_NAME, loadFileEnv, mergeEnv } from "./config.file.ts";

/** In-memory filesystem stub over a path to content map. */
function stubFs(files: Record<string, string>) {
  return {
    exists: (p: string) => p in files,
    read: (p: string) => {
      if (!(p in files)) throw new Error(`ENOENT: ${p}`);
      return files[p];
    },
  };
}

const AGENT = "/home/u/.pi/agent";
const CWD = "/work/repo";
const GLOBAL = join(AGENT, CONFIG_FILE_NAME);
const PROJECT = join(CWD, ".pi", CONFIG_FILE_NAME);

test("empty-when-no-files", () => {
  const env = loadFileEnv({ agentDir: AGENT, cwd: CWD, ...stubFs({}) });
  assert.deepEqual(env, {});
});

test("reads-global-scope", () => {
  const env = loadFileEnv({
    agentDir: AGENT,
    cwd: CWD,
    ...stubFs({ [GLOBAL]: JSON.stringify({ PI_AGENT_ENABLE_TELEMETRY: "on" }) }),
  });
  assert.equal(env.PI_AGENT_ENABLE_TELEMETRY, "on");
});

test("reads-project-scope", () => {
  const env = loadFileEnv({
    agentDir: AGENT,
    cwd: CWD,
    ...stubFs({ [PROJECT]: JSON.stringify({ OTEL_EXPORTER_OTLP_ENDPOINT: "http://localhost:24317" }) }),
  });
  assert.equal(env.OTEL_EXPORTER_OTLP_ENDPOINT, "http://localhost:24317");
});

test("project-overrides-global", () => {
  const env = loadFileEnv({
    agentDir: AGENT,
    cwd: CWD,
    ...stubFs({
      [GLOBAL]: JSON.stringify({ PI_AGENT_ENABLE_TELEMETRY: "off", OTEL_SERVICE_NAME: "global" }),
      [PROJECT]: JSON.stringify({ PI_AGENT_ENABLE_TELEMETRY: "on" }),
    }),
  });
  // Shared key: project wins. Global-only key: passes through.
  assert.equal(env.PI_AGENT_ENABLE_TELEMETRY, "on");
  assert.equal(env.OTEL_SERVICE_NAME, "global");
});

test("coerces-scalars-and-drops-objects", () => {
  const env = loadFileEnv({
    agentDir: AGENT,
    cwd: CWD,
    ...stubFs({
      [GLOBAL]: JSON.stringify({
        OTEL_METRIC_EXPORT_INTERVAL: 1000,
        PI_AGENT_ENABLE_TELEMETRY: true,
        nested: { a: 1 },
        list: [1, 2],
        blank: null,
      }),
    }),
  });
  assert.equal(env.OTEL_METRIC_EXPORT_INTERVAL, "1000");
  assert.equal(env.PI_AGENT_ENABLE_TELEMETRY, "true");
  assert.equal("nested" in env, false);
  assert.equal("list" in env, false);
  assert.equal("blank" in env, false);
});

test("malformed-json-degrades-to-empty", () => {
  const env = loadFileEnv({
    agentDir: AGENT,
    cwd: CWD,
    ...stubFs({ [GLOBAL]: "{ not json" }),
  });
  assert.deepEqual(env, {});
});

test("non-object-json-degrades-to-empty", () => {
  const env = loadFileEnv({
    agentDir: AGENT,
    cwd: CWD,
    ...stubFs({ [GLOBAL]: JSON.stringify([1, 2, 3]) }),
  });
  assert.deepEqual(env, {});
});

test("merge-env-lets-environment-win", () => {
  const fileEnv = { PI_AGENT_ENABLE_TELEMETRY: "on", OTEL_SERVICE_NAME: "from-file" };
  const merged = mergeEnv(fileEnv, { OTEL_SERVICE_NAME: "from-env" });
  // Environment wins for a shared key; file-only key passes through.
  assert.equal(merged.OTEL_SERVICE_NAME, "from-env");
  assert.equal(merged.PI_AGENT_ENABLE_TELEMETRY, "on");
});

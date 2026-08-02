/**
 * @agents-index End-to-end exporter test that loads this extension through the
 *   real pi SDK loader (@earendil-works/pi-coding-agent) exactly as pi loads it,
 *   drives pi lifecycle events, and asserts the three OTLP gRPC signals actually
 *   arrive at an in-process collector carrying the expected resource service name;
 *   also asserts the core no-op promise: switched off or with no collector
 *   reachable, nothing is exported and no error escapes.
 *
 * Why: the package's whole failure mode is installing cleanly and doing nothing.
 * The 29 unit tests exercise the parts in isolation; nothing else proves that pi
 * resolves the pi.extensions manifest, loads the TypeScript entry through jiti,
 * builds a real ExtensionAPI, and that the wired providers put metrics, logs, and
 * spans on the wire. This test closes that gap by using pi's own
 * discoverAndLoadExtensions (the same code path pi runs), so a broken files list,
 * a broken manifest entry, or a broken provider wiring fails here rather than in a
 * user's silent install.
 *
 * How the OTLP receiver is built: an in-process @grpc/grpc-js server (already a
 * package dependency, so no new proto tooling) registers the three OTLP collector
 * service methods with passthrough (identity) serializers. The server therefore
 * captures each Export request as the exact protobuf bytes the exporter put on the
 * wire. Assertions search those bytes for the length-delimited UTF-8 of the
 * resource key `service.name`, its value, and the signal's own instrument, event,
 * and span names. This is the lightest approach that genuinely asserts wire
 * content: it needs no .proto files, no protobufjs, and no request-side decoder
 * (the otlp-transformer package exposes only response deserialization), yet it
 * verifies the bytes a real collector would parse.
 */

import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { after, test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import * as grpc from "@grpc/grpc-js";
import { metrics } from "@opentelemetry/api";
import { logs } from "@opentelemetry/api-logs";
import { trace } from "@opentelemetry/api";

/** The distinctive service.name asserted on every signal's resource. */
const SERVICE_NAME = "pi-otel-exporter-test";

/** OTLP gRPC unary method paths for the three collector services. */
const METHOD_PATH = {
  metrics: "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export",
  logs: "/opentelemetry.proto.collector.logs.v1.LogsService/Export",
  traces: "/opentelemetry.proto.collector.trace.v1.TraceService/Export",
} as const;

/** Passthrough gRPC codec: the server keeps the raw request/response bytes. */
const RAW = (b: Buffer): Buffer => b;

/**
 * Build a unary OTLP method definition whose codecs are identity, so the server
 * captures the exporter's exact protobuf bytes.
 *
 * @param methodPath - The fully-qualified gRPC method path.
 * @returns A grpc-js method definition over Buffers.
 */
function unary(methodPath: string): grpc.MethodDefinition<Buffer, Buffer> {
  return {
    path: methodPath,
    requestStream: false,
    responseStream: false,
    requestSerialize: RAW,
    requestDeserialize: RAW,
    responseSerialize: RAW,
    responseDeserialize: RAW,
  };
}

/** A running in-process OTLP receiver plus the bytes it has captured per signal. */
interface Receiver {
  port: number;
  captured: Record<"metrics" | "logs" | "traces", Buffer[]>;
  /** All captured bytes for one signal, concatenated. */
  bytesFor(signal: "metrics" | "logs" | "traces"): Buffer;
  /** Total number of Export requests received across all signals. */
  total(): number;
  shutdown(): void;
}

/**
 * Stand up an in-process OTLP gRPC receiver on an ephemeral loopback port that
 * records every Export request's raw protobuf bytes.
 *
 * @returns The started {@link Receiver}.
 */
async function startReceiver(): Promise<Receiver> {
  const captured: Receiver["captured"] = { metrics: [], logs: [], traces: [] };
  const server = new grpc.Server();
  for (const signal of ["metrics", "logs", "traces"] as const) {
    server.addService({ export: unary(METHOD_PATH[signal]) }, {
      export: (call: grpc.ServerUnaryCall<Buffer, Buffer>, cb: grpc.sendUnaryData<Buffer>) => {
        captured[signal].push(call.request);
        // An empty ExportServiceResponse: every field is optional, so zero bytes
        // is a valid response the real exporter deserializes without error.
        cb(null, Buffer.alloc(0));
      },
    });
  }
  const port = await new Promise<number>((resolve, reject) => {
    server.bindAsync("127.0.0.1:0", grpc.ServerCredentials.createInsecure(), (err, p) =>
      err ? reject(err) : resolve(p),
    );
  });
  return {
    port,
    captured,
    bytesFor: (signal) => Buffer.concat(captured[signal]),
    total: () => captured.metrics.length + captured.logs.length + captured.traces.length,
    shutdown: () => server.forceShutdown(),
  };
}

/** A loaded extension: the handler map pi built, and any load errors pi reported. */
interface LoadedExtension {
  handlers: Map<string, Array<(event: unknown, ctx: unknown) => unknown>>;
  errors: Array<{ path: string; error: string }>;
}

/**
 * Resolve the path to pi's own extension loader inside the installed SDK. The
 * loader is not re-exported from the package entry (a deliberate circular-import
 * avoidance in pi), so it is imported by absolute file path rather than by
 * package specifier.
 *
 * @returns Absolute path to the SDK's dist/core/extensions/loader.js.
 */
function piLoaderPath(): string {
  const mainPath = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"));
  const sdkRoot = path.resolve(path.dirname(mainPath), "..");
  return path.join(sdkRoot, "dist/core/extensions/loader.js");
}

/**
 * Load this package through pi's real loader exactly as pi does at startup:
 * discoverAndLoadExtensions resolves the pi.extensions manifest entry from the
 * package directory, loads the TypeScript entry through jiti, and invokes the
 * factory with a real ExtensionAPI. The cwd and agentDir are pointed at an empty
 * temporary directory so pi discovers only this package and none of the machine's
 * own installed extensions.
 *
 * @returns The extension's handler map and any load errors pi reported.
 */
async function loadThroughPi(): Promise<LoadedExtension> {
  const emptyDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-otel-e2e-"));
  const loader = (await import(pathToFileURL(piLoaderPath()).href)) as {
    discoverAndLoadExtensions: (
      configuredPaths: string[],
      cwd: string,
      agentDir?: string,
    ) => Promise<{
      extensions: Array<{ handlers: LoadedExtension["handlers"] }>;
      errors: LoadedExtension["errors"];
    }>;
  };
  const pkgDir = path.resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
  const result = await loader.discoverAndLoadExtensions([pkgDir], emptyDir, emptyDir);
  const ext = result.extensions[0];
  return { handlers: ext ? ext.handlers : new Map(), errors: result.errors };
}

/**
 * Fire every handler registered for a lifecycle event, awaiting async handlers
 * (agent_end and session_shutdown flush asynchronously).
 *
 * @param loaded - The loaded extension.
 * @param event - The pi lifecycle event name.
 * @param payload - The synthetic event payload.
 */
async function fire(loaded: LoadedExtension, event: string, payload: unknown): Promise<void> {
  for (const handler of loaded.handlers.get(event) ?? []) await handler(payload, {});
}

/**
 * Drive one full pi interaction that exercises all three signals: a session
 * start (metrics), a user prompt (logs and the interaction span), a provider
 * request and a finalized assistant message (token and cost metrics, the
 * api_request and assistant_response logs, the llm_request span), and agent_end
 * (closes the interaction span and force-flushes every signal).
 *
 * @param loaded - The loaded extension whose handlers are driven.
 */
async function driveInteraction(loaded: LoadedExtension): Promise<void> {
  await fire(loaded, "session_start", { reason: "cli_startup" });
  await fire(loaded, "before_agent_start", { prompt: "hello telemetry" });
  await fire(loaded, "agent_start", {});
  await fire(loaded, "before_provider_request", {});
  await fire(loaded, "message_end", {
    message: {
      role: "assistant",
      model: "test-model",
      id: "resp-1",
      content: "hi there",
      usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, cost: { total: 0.01 } },
    },
  });
  await fire(loaded, "agent_end", {});
}

/** Reset the global OTel providers so a fresh enabled load registers cleanly. */
function resetGlobalProviders(): void {
  metrics.disable();
  logs.disable();
  trace.disable();
}

/** Environment keys this test mutates; snapshotted and restored around each case. */
const ENV_KEYS = ["PI_OTEL_ENABLE", "OTEL_SERVICE_NAME", "OTEL_EXPORTER_OTLP_ENDPOINT"];

/**
 * Run a body with a temporary environment, restoring the prior environment and
 * the global OTel providers afterwards.
 *
 * @param env - Environment overrides to apply for the body.
 * @param body - The async body to run under the overrides.
 */
async function withEnv(env: Record<string, string>, body: () => Promise<void>): Promise<void> {
  const saved: Record<string, string | undefined> = {};
  for (const k of ENV_KEYS) saved[k] = process.env[k];
  resetGlobalProviders();
  Object.assign(process.env, env);
  try {
    await body();
  } finally {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
    resetGlobalProviders();
  }
}

/**
 * Poll until a predicate holds or the deadline passes. Used to wait for the
 * asynchronous gRPC export to reach the receiver after force-flush resolves.
 *
 * @param predicate - Condition to wait for.
 * @param timeoutMs - Maximum time to wait.
 */
async function waitFor(predicate: () => boolean, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate() && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 25));
  }
}

after(() => resetGlobalProviders());

test("pi loads the extension and all three signals reach the collector", async () => {
  const receiver = await startReceiver();
  try {
    await withEnv(
      {
        PI_OTEL_ENABLE: "1",
        OTEL_SERVICE_NAME: SERVICE_NAME,
        OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${receiver.port}`,
      },
      async () => {
        const loaded = await loadThroughPi();

        // pi resolved the manifest, loaded the TypeScript entry through jiti, and
        // ran the factory with no error. A broken files list or manifest entry
        // surfaces here as a load error rather than a silent no-op.
        assert.deepEqual(loaded.errors, [], "pi loaded the extension with no error");
        assert.ok(loaded.handlers.has("session_start"), "lifecycle handlers registered");
        assert.ok(loaded.handlers.has("agent_end"), "agent_end flush registered");

        await driveInteraction(loaded);
        await waitFor(
          () =>
            receiver.captured.metrics.length > 0 &&
            receiver.captured.logs.length > 0 &&
            receiver.captured.traces.length > 0,
        );

        const svc = Buffer.from(SERVICE_NAME);
        const key = Buffer.from("service.name");
        for (const signal of ["metrics", "logs", "traces"] as const) {
          const bytes = receiver.bytesFor(signal);
          assert.ok(receiver.captured[signal].length > 0, `${signal} export arrived`);
          assert.ok(bytes.includes(key), `${signal} resource carries the service.name key`);
          assert.ok(bytes.includes(svc), `${signal} resource carries service name ${SERVICE_NAME}`);
        }

        // Each signal put its own pi.* payload on the wire, not just an empty
        // envelope: a metric instrument, a log event name, and a span name.
        assert.ok(
          receiver.bytesFor("metrics").includes(Buffer.from("pi.session.count")),
          "metrics carry the pi.session.count instrument",
        );
        assert.ok(
          receiver.bytesFor("logs").includes(Buffer.from("pi.user_prompt")),
          "logs carry the pi.user_prompt event",
        );
        assert.ok(
          receiver.bytesFor("traces").includes(Buffer.from("pi.interaction")),
          "traces carry the pi.interaction span",
        );

        // Close the exporter channels so the test process has no dangling gRPC
        // connections.
        await fire(loaded, "session_shutdown", {});
      },
    );
  } finally {
    receiver.shutdown();
  }
});

test("no-op when the master switch is off: nothing is exported and no error escapes", async () => {
  const receiver = await startReceiver();
  try {
    await withEnv(
      {
        PI_OTEL_ENABLE: "0",
        OTEL_SERVICE_NAME: SERVICE_NAME,
        OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${receiver.port}`,
      },
      async () => {
        const loaded = await loadThroughPi();

        // Switched off, the factory constructs no exporter and registers no
        // handler; loading still succeeds without error.
        assert.deepEqual(loaded.errors, [], "the disabled extension loads without error");
        assert.equal(loaded.handlers.size, 0, "the disabled extension registers no handlers");

        // Driving the lifecycle fires nothing, so the receiver stays empty.
        await assert.doesNotReject(() => driveInteraction(loaded));
        await waitFor(() => receiver.total() > 0, 500);
        assert.equal(receiver.total(), 0, "no signal reached the collector when switched off");
      },
    );
  } finally {
    receiver.shutdown();
  }
});

test("silent when the collector is unreachable: no throw, and no error escapes", async () => {
  // A guaranteed-closed port: bind a throwaway server, capture its port, shut it
  // down. The exporter's gRPC connection to it can never succeed.
  const throwaway = await startReceiver();
  const deadPort = throwaway.port;
  throwaway.shutdown();

  await withEnv(
    {
      PI_OTEL_ENABLE: "1",
      OTEL_SERVICE_NAME: SERVICE_NAME,
      OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${deadPort}`,
    },
    async () => {
      const loaded = await loadThroughPi();
      assert.deepEqual(loaded.errors, [], "the extension loads even with a dead endpoint");

      // The whole interaction, including the agent_end force-flush against a dead
      // collector, must complete without a rejection reaching pi (NFR2, FR15).
      await assert.doesNotReject(
        () => driveInteraction(loaded),
        "an unreachable collector never raises into the agent",
      );
      await assert.doesNotReject(() => fire(loaded, "session_shutdown", {}));
    },
  );
});

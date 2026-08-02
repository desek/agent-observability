/**
 * @agents-index Builds the OpenTelemetry Resource and the meter, logger, and
 *   tracer providers from a resolved OtelParityConfig, selecting the OTLP gRPC or
 *   OTLP HTTP/protobuf exporter per signal from that signal's resolved protocol,
 *   and exposes a single flush/shutdown handle so short pi sessions do not lose
 *   buffered telemetry.
 *
 * Why: the three signals (metrics, logs, traces) each need a provider wired to an
 * OTLP exporter pointed at the local collector, sharing one Resource that carries
 * service.name and OTEL_RESOURCE_ATTRIBUTES provenance (FR3). Each signal honours
 * its own OTEL_EXPORTER_OTLP(_SIGNAL)_PROTOCOL: `grpc` (the default) builds the
 * gRPC exporter, `http/protobuf` builds the HTTP/protobuf exporter, so a user may
 * send one signal over HTTP and another over gRPC in the same run. An unsupported
 * protocol value rejects that one signal with an actionable diagnostic rather than
 * silently exporting over gRPC, and leaves the other signals unaffected. This
 * module is the single place that touches the OTel SDK constructors so the
 * emitters downstream depend only on the returned provider handles, and the index
 * factory has one `shutdown()` to call on `session_shutdown` (NFR5). Signals
 * selected as `none` are skipped entirely with no fallback sink (FR12).
 */

import { Metadata } from "@grpc/grpc-js";
import { metrics, type MeterProvider as ApiMeterProvider } from "@opentelemetry/api";
import { logs, type LoggerProvider as ApiLoggerProvider } from "@opentelemetry/api-logs";
import {
  defaultResource,
  resourceFromAttributes,
  type Resource,
} from "@opentelemetry/resources";
import {
  MeterProvider,
  PeriodicExportingMetricReader,
  type PushMetricExporter,
} from "@opentelemetry/sdk-metrics";
import {
  BatchLogRecordProcessor,
  LoggerProvider,
  type LogRecordExporter,
} from "@opentelemetry/sdk-logs";
import {
  BasicTracerProvider,
  BatchSpanProcessor,
  type SpanExporter,
  type Tracer,
} from "@opentelemetry/sdk-trace-base";
import { OTLPMetricExporter as OTLPMetricExporterGrpc } from "@opentelemetry/exporter-metrics-otlp-grpc";
import { OTLPLogExporter as OTLPLogExporterGrpc } from "@opentelemetry/exporter-logs-otlp-grpc";
import { OTLPTraceExporter as OTLPTraceExporterGrpc } from "@opentelemetry/exporter-trace-otlp-grpc";
import { OTLPMetricExporter as OTLPMetricExporterHttp } from "@opentelemetry/exporter-metrics-otlp-http";
import { OTLPLogExporter as OTLPLogExporterHttp } from "@opentelemetry/exporter-logs-otlp-http";
import { OTLPTraceExporter as OTLPTraceExporterHttp } from "@opentelemetry/exporter-trace-otlp-http";

import type { OtelParityConfig, OtelSignal, SignalExporterConfig } from "./config.env.ts";

/** Resource attribute key for the logical service name (service.name). */
const ATTR_SERVICE_NAME = "service.name";

/**
 * The initialized provider handles the signal emitters use, plus a unified
 * shutdown that flushes and tears down every provider that was created.
 *
 * @property meterProvider - MeterProvider for pi.* metric instruments, or
 *   undefined when the metrics signal is disabled.
 * @property loggerProvider - LoggerProvider for pi.* log events, or undefined
 *   when the logs signal is disabled.
 * @property tracer - Tracer for the pi.* span hierarchy, or undefined when the
 *   traces signal is disabled.
 * @property forceFlush - Flushes all pending batched telemetry without tearing
 *   down the providers; called on agent_end so headless `pi -p` sessions (whose
 *   `session_shutdown` never fires) still deliver their buffered logs and spans.
 * @property shutdown - Flushes and shuts down all created providers; safe to
 *   call once on session_shutdown.
 */
export interface OtelProviders {
  meterProvider?: MeterProvider;
  loggerProvider?: LoggerProvider;
  tracer?: Tracer;
  forceFlush: () => Promise<void>;
  shutdown: () => Promise<void>;
}

/** Instrumentation scope name recorded on every emitted signal. */
export const INSTRUMENTATION_SCOPE = "pi-pi-opentelemetry";

/**
 * Build the shared OTel Resource: service.name (default pi-coding-agent) merged
 * with the process default resource and any OTEL_RESOURCE_ATTRIBUTES provenance
 * (git.org/repo/branch/path in this repo). Honours OTEL_SERVICE_NAME via the
 * config's resolved serviceName (FR3).
 *
 * @param config - Resolved pi-opentelemetry configuration.
 * @returns The merged Resource applied to all three providers.
 */
export function buildResource(config: OtelParityConfig): Resource {
  return defaultResource().merge(
    resourceFromAttributes({
      [ATTR_SERVICE_NAME]: config.serviceName,
      ...config.resourceAttributes,
    }),
  );
}

/**
 * Convert parsed OTEL_EXPORTER_OTLP_HEADERS into gRPC Metadata for the OTLP gRPC
 * exporters, or undefined when no headers are configured.
 *
 * @param headers - Parsed header key/value pairs.
 * @returns gRPC Metadata, or undefined when empty.
 */
function toMetadata(headers: Record<string, string>): Metadata | undefined {
  const keys = Object.keys(headers);
  if (keys.length === 0) return undefined;
  const md = new Metadata();
  for (const key of keys) md.set(key, headers[key]);
  return md;
}

/**
 * The OTLP transports this extension can build an exporter for. A resolved
 * protocol string maps to exactly one of these, or to `undefined` when the value
 * is unsupported (see {@link resolveTransport}).
 */
export type OtlpTransport = "grpc" | "http/protobuf";

/**
 * The protocol values this extension supports, in the order the diagnostic lists
 * them: `grpc` is the default, `http/protobuf` is the HTTP alternative. Any other
 * value is rejected. `http/json` is deliberately absent: the SDK ships no JSON
 * exporter for the Node signals, so accepting it would be a promise this package
 * cannot keep.
 */
export const SUPPORTED_OTLP_PROTOCOLS: readonly OtlpTransport[] = ["grpc", "http/protobuf"];

/**
 * Map a resolved per-signal protocol string to an {@link OtlpTransport}, or
 * `undefined` when the value names no transport this extension can build.
 *
 * The empty string and `grpc` both select gRPC, keeping the default and the
 * unset case on today's transport. The match is case-insensitive and trimmed so
 * `HTTP/PROTOBUF` and stray whitespace resolve the same way the SDK's own env
 * reader would.
 *
 * @param protocol - The signal's resolved protocol string.
 * @returns The transport to build, or undefined when the value is unsupported.
 */
export function resolveTransport(protocol: string): OtlpTransport | undefined {
  const v = protocol.trim().toLowerCase();
  if (v === "" || v === "grpc") return "grpc";
  if (v === "http/protobuf") return "http/protobuf";
  return undefined;
}

/** OTLP HTTP resource path each signal posts to, appended to the base endpoint. */
const HTTP_RESOURCE_PATH: Record<OtelSignal, string> = {
  metrics: "v1/metrics",
  logs: "v1/logs",
  traces: "v1/traces",
};

/**
 * Build the full OTLP HTTP URL for one signal from the resolved endpoint. When
 * the endpoint is a base (the default `http://localhost:4317`, or any host set
 * through OTEL_EXPORTER_OTLP_ENDPOINT), the standard `/v1/{signal}` resource path
 * is appended, matching the OTLP HTTP specification and the SDK's own default so
 * the export reaches a real collector's signal route.
 *
 * @param endpoint - The signal's resolved base endpoint.
 * @param signal - The signal whose resource path is appended.
 * @returns The full URL the HTTP exporter posts to.
 */
function httpSignalUrl(endpoint: string, signal: OtelSignal): string {
  return `${endpoint.replace(/\/+$/, "")}/${HTTP_RESOURCE_PATH[signal]}`;
}

/**
 * Shared OTLP gRPC exporter options for one signal: the resolved endpoint URL
 * used verbatim and optional header metadata.
 *
 * @param signal - Resolved per-signal exporter config.
 * @param metadata - Optional gRPC header metadata.
 * @returns Options object accepted by all three OTLP gRPC exporter constructors.
 */
function grpcOptions(
  signal: SignalExporterConfig,
  metadata: Metadata | undefined,
): { url: string; metadata?: Metadata } {
  return metadata ? { url: signal.endpoint, metadata } : { url: signal.endpoint };
}

/**
 * Shared OTLP HTTP/protobuf exporter options for one signal: the full signal URL
 * and, unlike gRPC, plain string headers (the HTTP exporters take a headers
 * record, not gRPC Metadata).
 *
 * @param signal - The signal whose resource path the URL carries.
 * @param config - Resolved per-signal exporter config supplying the endpoint.
 * @param headers - Parsed OTEL_EXPORTER_OTLP_HEADERS, applied when non-empty.
 * @returns Options object accepted by all three OTLP HTTP exporter constructors.
 */
function httpOptions(
  signal: OtelSignal,
  config: SignalExporterConfig,
  headers: Record<string, string>,
): { url: string; headers?: Record<string, string> } {
  const url = httpSignalUrl(config.endpoint, signal);
  return Object.keys(headers).length > 0 ? { url, headers } : { url };
}

/**
 * Emit the actionable diagnostic for an unsupported protocol on one signal, to
 * stderr so it is visible to the operator without being routed through the OTel
 * pipeline it is reporting a fault in. The message names the offending value, the
 * signal it disables, the supported values with the default called out, the exact
 * variables to change, and what to verify afterwards, so the reader can act rather
 * than only diagnose. It never throws: the caller has already decided this signal
 * does not export, and telemetry must never break pi (FR15, NFR2).
 *
 * @param signal - The signal that will not export.
 * @param protocol - The unsupported protocol value that was resolved for it.
 */
function warnUnsupportedProtocol(signal: OtelSignal, protocol: string): void {
  const supported = SUPPORTED_OTLP_PROTOCOLS.map((p) => `"${p}"`).join(" or ");
  const perSignal = `OTEL_EXPORTER_OTLP_${signal.toUpperCase()}_PROTOCOL`;
  process.stderr.write(
    `pi-opentelemetry: otel.providers.ts: the ${signal} signal is not exported ` +
      `because the OTLP protocol "${protocol}" is not supported. ` +
      `Supported values are ${supported} (grpc is the default). ` +
      `To fix, set OTEL_EXPORTER_OTLP_PROTOCOL (or the per-signal ${perSignal}) ` +
      `to one of those values, or unset it to use the gRPC default. ` +
      `The other signals are unaffected. ` +
      `After changing it, re-run and confirm ${signal} arrive at your collector.\n`,
  );
}

/**
 * Build the metrics exporter for the selected transport.
 *
 * @param transport - The resolved transport to build.
 * @param config - Resolved per-signal exporter config.
 * @param metadata - Optional gRPC header metadata (gRPC transport only).
 * @param headers - Parsed headers as strings (HTTP transport only).
 * @returns A push metric exporter for the chosen transport.
 */
function buildMetricExporter(
  transport: OtlpTransport,
  config: SignalExporterConfig,
  metadata: Metadata | undefined,
  headers: Record<string, string>,
): PushMetricExporter {
  return transport === "grpc"
    ? new OTLPMetricExporterGrpc(grpcOptions(config, metadata))
    : new OTLPMetricExporterHttp(httpOptions("metrics", config, headers));
}

/**
 * Build the logs exporter for the selected transport.
 *
 * @param transport - The resolved transport to build.
 * @param config - Resolved per-signal exporter config.
 * @param metadata - Optional gRPC header metadata (gRPC transport only).
 * @param headers - Parsed headers as strings (HTTP transport only).
 * @returns A log record exporter for the chosen transport.
 */
function buildLogExporter(
  transport: OtlpTransport,
  config: SignalExporterConfig,
  metadata: Metadata | undefined,
  headers: Record<string, string>,
): LogRecordExporter {
  return transport === "grpc"
    ? new OTLPLogExporterGrpc(grpcOptions(config, metadata))
    : new OTLPLogExporterHttp(httpOptions("logs", config, headers));
}

/**
 * Build the traces exporter for the selected transport.
 *
 * @param transport - The resolved transport to build.
 * @param config - Resolved per-signal exporter config.
 * @param metadata - Optional gRPC header metadata (gRPC transport only).
 * @param headers - Parsed headers as strings (HTTP transport only).
 * @returns A span exporter for the chosen transport.
 */
function buildTraceExporter(
  transport: OtlpTransport,
  config: SignalExporterConfig,
  metadata: Metadata | undefined,
  headers: Record<string, string>,
): SpanExporter {
  return transport === "grpc"
    ? new OTLPTraceExporterGrpc(grpcOptions(config, metadata))
    : new OTLPTraceExporterHttp(httpOptions("traces", config, headers));
}

/**
 * Initialize the meter, logger, and tracer providers from a resolved config,
 * register them as the global providers, and return their handles with a
 * unified shutdown.
 *
 * Each signal is created only when its selection is `otlp` and its resolved
 * protocol names a supported transport (`grpc` or `http/protobuf`). A `none`
 * selection, or an unsupported protocol, leaves that provider undefined with no
 * fallback sink (FR12); an unsupported protocol also emits an actionable
 * diagnostic and never throws, so one bad signal does not disable the others and
 * telemetry never breaks pi (FR15, NFR2). Callers must have already verified
 * PI_OTEL_ENABLE (FR11) before invoking this.
 *
 * @param config - Resolved pi-opentelemetry configuration.
 * @returns The initialized {@link OtelProviders} handle.
 */
export function initProviders(config: OtelParityConfig): OtelProviders {
  const resource = buildResource(config);
  const metadata = toMetadata(config.headers);
  const shutdowns: Array<() => Promise<void>> = [];
  const flushes: Array<() => Promise<void>> = [];

  // Per-signal transport resolution: each signal keeps `undefined` when it is
  // selected `none`, or when its resolved protocol is unsupported. In the
  // unsupported case the diagnostic is emitted here and the signal is left
  // unbuilt, so it does not export while the other signals are unaffected.
  const transportFor = (signal: OtelSignal): OtlpTransport | undefined => {
    if (config.selection[signal] !== "otlp") return undefined;
    const transport = resolveTransport(config.exporters[signal].protocol);
    if (transport === undefined) {
      warnUnsupportedProtocol(signal, config.exporters[signal].protocol);
      return undefined;
    }
    return transport;
  };

  let meterProvider: MeterProvider | undefined;
  const metricsTransport = transportFor("metrics");
  if (metricsTransport !== undefined) {
    const reader = new PeriodicExportingMetricReader({
      exporter: buildMetricExporter(
        metricsTransport,
        config.exporters.metrics,
        metadata,
        config.headers,
      ),
      ...(config.exporters.metrics.exportIntervalMillis !== undefined
        ? { exportIntervalMillis: config.exporters.metrics.exportIntervalMillis }
        : {}),
    });
    meterProvider = new MeterProvider({ resource, readers: [reader] });
    metrics.setGlobalMeterProvider(meterProvider as unknown as ApiMeterProvider);
    flushes.push(() => meterProvider!.forceFlush());
    shutdowns.push(() => meterProvider!.shutdown());
  }

  let loggerProvider: LoggerProvider | undefined;
  const logsTransport = transportFor("logs");
  if (logsTransport !== undefined) {
    // sdk-logs takes a single options object with `exporter` (NOT the positional
    // `(exporter, config)` shape the trace/span processor uses). Passing the
    // exporter positionally leaves `options.exporter` undefined, so every log
    // export throws inside the batch processor and is swallowed by the global
    // error handler — logs silently never reach Loki. Build the options object.
    const processor = new BatchLogRecordProcessor({
      exporter: buildLogExporter(
        logsTransport,
        config.exporters.logs,
        metadata,
        config.headers,
      ),
      ...(config.exporters.logs.exportIntervalMillis !== undefined
        ? { scheduledDelayMillis: config.exporters.logs.exportIntervalMillis }
        : {}),
    });
    loggerProvider = new LoggerProvider({ resource, processors: [processor] });
    logs.setGlobalLoggerProvider(loggerProvider as unknown as ApiLoggerProvider);
    flushes.push(() => loggerProvider!.forceFlush());
    shutdowns.push(() => loggerProvider!.shutdown());
  }

  let tracer: Tracer | undefined;
  let tracerProvider: BasicTracerProvider | undefined;
  const tracesTransport = transportFor("traces");
  if (tracesTransport !== undefined) {
    const processor = new BatchSpanProcessor(
      buildTraceExporter(
        tracesTransport,
        config.exporters.traces,
        metadata,
        config.headers,
      ),
      config.exporters.traces.exportIntervalMillis !== undefined
        ? { scheduledDelayMillis: config.exporters.traces.exportIntervalMillis }
        : undefined,
    );
    tracerProvider = new BasicTracerProvider({ resource, spanProcessors: [processor] });
    tracer = tracerProvider.getTracer(INSTRUMENTATION_SCOPE);
    flushes.push(() => tracerProvider!.forceFlush());
    shutdowns.push(() => tracerProvider!.shutdown());
  }

  return {
    meterProvider,
    loggerProvider,
    tracer,
    async forceFlush() {
      for (const fn of flushes) {
        try {
          await fn();
        } catch {
          // Fail safe: a flush failure must never break pi's agent loop (NFR2).
        }
      }
    },
    async shutdown() {
      for (const fn of shutdowns) {
        try {
          await fn();
        } catch {
          // Fail safe: a stuck or failed exporter shutdown must never block or
          // crash the pi session teardown (NFR2).
        }
      }
    },
  };
}

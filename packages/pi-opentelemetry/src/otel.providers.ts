/**
 * @agents-index Builds the OpenTelemetry Resource and the meter, logger, and
 *   tracer providers with OTLP gRPC exporters from a resolved OtelParityConfig,
 *   and exposes a single flush/shutdown handle so short pi sessions do not lose
 *   buffered telemetry.
 *
 * Why: the three signals (metrics, logs, traces) each need a provider wired to
 * an OTLP gRPC exporter pointed at the local Alloy receiver, sharing one Resource
 * that carries service.name and OTEL_RESOURCE_ATTRIBUTES provenance (FR3). This
 * module is the single place that touches the OTel SDK constructors so the
 * emitters downstream depend only on the returned provider handles, and the
 * index factory has one `shutdown()` to call on `session_shutdown` (NFR5).
 * Signals selected as `none` are skipped entirely with no fallback sink (FR12).
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
} from "@opentelemetry/sdk-metrics";
import {
  BatchLogRecordProcessor,
  LoggerProvider,
} from "@opentelemetry/sdk-logs";
import {
  BasicTracerProvider,
  BatchSpanProcessor,
  type Tracer,
} from "@opentelemetry/sdk-trace-base";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-grpc";
import { OTLPLogExporter } from "@opentelemetry/exporter-logs-otlp-grpc";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-grpc";

import type { OtelParityConfig, SignalExporterConfig } from "./config.env.ts";

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
 * Shared OTLP gRPC exporter options for one signal: the resolved endpoint URL
 * and optional header metadata.
 *
 * @param signal - Resolved per-signal exporter config.
 * @param metadata - Optional gRPC header metadata.
 * @returns Options object accepted by all three OTLP gRPC exporter constructors.
 */
function exporterOptions(
  signal: SignalExporterConfig,
  metadata: Metadata | undefined,
): { url: string; metadata?: Metadata } {
  return metadata ? { url: signal.endpoint, metadata } : { url: signal.endpoint };
}

/**
 * Initialize the meter, logger, and tracer providers from a resolved config,
 * register them as the global providers, and return their handles with a
 * unified shutdown.
 *
 * Each signal is created only when its selection is `otlp`; a `none` selection
 * leaves that provider undefined with no fallback sink (FR12). Callers must have
 * already verified PI_OTEL_ENABLE (FR11) before invoking this.
 *
 * @param config - Resolved pi-opentelemetry configuration.
 * @returns The initialized {@link OtelProviders} handle.
 */
export function initProviders(config: OtelParityConfig): OtelProviders {
  const resource = buildResource(config);
  const metadata = toMetadata(config.headers);
  const shutdowns: Array<() => Promise<void>> = [];
  const flushes: Array<() => Promise<void>> = [];

  let meterProvider: MeterProvider | undefined;
  if (config.selection.metrics === "otlp") {
    const reader = new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter(
        exporterOptions(config.exporters.metrics, metadata),
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
  if (config.selection.logs === "otlp") {
    // sdk-logs takes a single options object with `exporter` (NOT the positional
    // `(exporter, config)` shape the trace/span processor uses). Passing the
    // exporter positionally leaves `options.exporter` undefined, so every log
    // export throws inside the batch processor and is swallowed by the global
    // error handler — logs silently never reach Loki. Build the options object.
    const processor = new BatchLogRecordProcessor({
      exporter: new OTLPLogExporter(exporterOptions(config.exporters.logs, metadata)),
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
  if (config.selection.traces === "otlp") {
    const processor = new BatchSpanProcessor(
      new OTLPTraceExporter(exporterOptions(config.exporters.traces, metadata)),
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

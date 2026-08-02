/**
 * @agents-index Default-export pi extension factory for pi-opentelemetry: reads the
 *   OTEL_* and PI_OTEL_ENABLE config, resolves the dynamic-default-enabled policy
 *   (explicit switch wins, else a local Alloy health probe decides), merges
 *   self-derived git provenance under any explicit OTEL_RESOURCE_ATTRIBUTES, and
 *   only when enabled initializes the OTLP gRPC providers and registers an
 *   agent_end force-flush plus a session_shutdown flush-and-teardown handler;
 *   otherwise no-ops with no exporter and no local fallback sink.
 *
 * Why: pi loads this module's default export with its ExtensionAPI. Phase 1
 * establishes the load-safe skeleton: an enabled extension stands up the meter,
 * logger, and tracer providers pointed at local Alloy over gRPC and guarantees
 * buffered telemetry is flushed on session teardown (NFR5), while a disabled or
 * unconfigured extension imposes zero cost and emits nothing (FR11, FR12). The
 * per-signal emitters (metrics/events/traces) are wired into the returned
 * providers in later phases; here the factory must load without error under pi
 * regardless of whether telemetry is enabled.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { loadConfig, resolveEnabled } from "./config.env.ts";
import { EventsEmitter } from "./events.emitter.ts";
import { probeAlloyHealthy } from "./health.alloy.ts";
import { MetricsEmitter } from "./metrics.emitter.ts";
import { initProviders, type OtelProviders } from "./otel.providers.ts";
import { deriveGitProvenance } from "./provenance.git.ts";
import { TracesEmitter } from "./traces.emitter.ts";

/**
 * Run a telemetry handler body fail-safe: any error is swallowed so a telemetry
 * fault can never crash, block, or slow pi's agent loop (NFR2).
 *
 * @param fn - The handler body to execute defensively.
 */
function failSafe(fn: () => void): void {
  try {
    fn();
  } catch {
    // Telemetry must never break pi (NFR2).
  }
}

/**
 * pi extension factory. Registered handlers are added only when telemetry is
 * enabled; the whole body is defensive so a telemetry failure can never crash or
 * block pi's agent loop (NFR2).
 *
 * The factory is async because the dynamic-default-enabled decision may probe
 * the local collector's health; pi awaits the returned promise before
 * session_start, so no lifecycle event is missed.
 *
 * @param pi - The pi ExtensionAPI handed to every extension factory.
 */
export default async function (pi: ExtensionAPI): Promise<void> {
  const parsed = loadConfig();

  // Dynamic default enabled: an explicit PI_OTEL_ENABLE wins; otherwise export is
  // enabled only when a target endpoint is configured or the local Alloy collector
  // is healthy, so an unconfigured machine emits nothing instead of hitting a dead
  // endpoint. Fail-safe: if the resolution itself throws, treat as disabled.
  let enabled = false;
  try {
    enabled = await resolveEnabled(parsed, () => probeAlloyHealthy());
  } catch {
    return;
  }
  if (!enabled) return;

  // Merge self-derived git provenance under any explicit OTEL_RESOURCE_ATTRIBUTES
  // (env wins): wired repos keep their exact configured provenance, un-wired repos
  // get zero-config per-repo provenance computed from the launch directory.
  let config = parsed;
  failSafe(() => {
    const derived = deriveGitProvenance();
    config = { ...parsed, resourceAttributes: { ...derived, ...parsed.resourceAttributes } };
  });

  let providers: OtelProviders | undefined;
  try {
    providers = initProviders(config);
  } catch {
    // Fail safe: if provider bootstrap throws (bad endpoint, missing transport),
    // the extension degrades to a no-op rather than breaking pi startup (NFR2).
    return;
  }

  // Metrics (Phase 2): the eight pi.* instruments, recorded from lifecycle
  // events. Each handler is fail-safe so a metric fault never breaks pi (NFR2,
  // FR6). Wired only when the metrics signal produced a MeterProvider.
  if (providers.meterProvider) {
    const metricsEmitter = new MetricsEmitter(providers.meterProvider, config);

    pi.on("session_start", (event) => {
      failSafe(() => metricsEmitter.recordSessionStart(event));
    });
    pi.on("message_end", (event) => {
      failSafe(() => metricsEmitter.recordMessageEnd(event));
    });
    pi.on("tool_result", (event) => {
      failSafe(() => metricsEmitter.recordToolResult(event));
    });
    pi.on("turn_start", (event) => {
      failSafe(() => metricsEmitter.turnStart(event.timestamp));
    });
    pi.on("turn_end", (event) => {
      failSafe(() => metricsEmitter.turnEnd(event.timestamp));
    });
  }

  // Events/logs (Phase 3): the pi.* log events, emitted from lifecycle events
  // with content-bearing fields gated behind the OTEL_LOG_* flags (FR7, FR9).
  // Each handler is fail-safe so a logging fault never breaks pi (NFR2). Wired
  // only when the logs signal produced a LoggerProvider.
  if (providers.loggerProvider) {
    const eventsEmitter = new EventsEmitter(providers.loggerProvider, config);

    pi.on("before_agent_start", (event) => {
      failSafe(() => eventsEmitter.userPrompt(event));
    });
    pi.on("message_end", (event) => {
      failSafe(() => eventsEmitter.messageEnd(event));
    });
    pi.on("tool_result", (event) => {
      failSafe(() => eventsEmitter.toolResult(event));
    });
    pi.on("tool_call", (event) => {
      failSafe(() => eventsEmitter.toolDecision(event));
    });
    pi.on("before_provider_request", (event) => {
      failSafe(() => eventsEmitter.apiRequestBody(event));
    });
    pi.on("after_provider_response", (event) => {
      failSafe(() => eventsEmitter.afterProviderResponse(event));
    });
    pi.on("session_compact", (event) => {
      failSafe(() => eventsEmitter.compaction(event));
    });
  }

  // Traces (Phase 4): the pi.interaction / pi.llm_request / pi.tool /
  // pi.tool.execution span hierarchy, opened and closed across pi's lifecycle
  // events with explicit parent-child nesting. Tool and prompt content ride only
  // when the OTEL_LOG_* flags are on (FR8, FR9). Each handler is fail-safe so a
  // tracing fault never breaks pi (NFR2). Wired only when the traces signal
  // produced a Tracer.
  if (providers.tracer) {
    const tracesEmitter = new TracesEmitter(providers.tracer, config);

    pi.on("before_agent_start", (event) => {
      failSafe(() => tracesEmitter.beforeAgentStart(event));
    });
    pi.on("agent_start", () => {
      failSafe(() => tracesEmitter.agentStart());
    });
    pi.on("agent_end", () => {
      failSafe(() => tracesEmitter.agentEnd());
    });
    pi.on("before_provider_request", () => {
      failSafe(() => tracesEmitter.llmRequestStart());
    });
    pi.on("message_end", (event) => {
      failSafe(() => tracesEmitter.messageEnd(event));
    });
    pi.on("tool_execution_start", (event) => {
      failSafe(() => tracesEmitter.toolExecutionStart(event));
    });
    pi.on("tool_execution_end", (event) => {
      failSafe(() => tracesEmitter.toolExecutionEnd(event));
    });
  }

  // Force-flush buffered telemetry when each agent loop finishes (agent_end). This
  // is the load-bearing delivery for short headless `pi -p` one-shots: the meter
  // reader and the batch log/span processors otherwise only export on their own
  // timers or at shutdown, and a one-shot can complete and begin tearing down
  // before those fire, dropping the run's logs and spans. agent_end fires at the
  // end of every completed agent loop (verified against pi 0.78.1 in print mode),
  // and forceFlush drains all three signals without tearing the providers down, so
  // interactive sessions that run many loops keep exporting afterwards. Awaited so
  // pi's event runner waits for the gRPC export to complete before proceeding.
  // Fail-safe per NFR2.
  pi.on("agent_end", async () => {
    try {
      await providers?.forceFlush();
    } catch {
      // A failed flush must never block or crash pi's agent loop (NFR2).
    }
  });

  // Flush and tear down on session_shutdown (quit, reload, and session-replacement
  // flows) so no buffered signal is lost on teardown (NFR5).
  pi.on("session_shutdown", async () => {
    try {
      await providers?.shutdown();
    } catch {
      // A failed flush must not block session teardown (NFR2).
    }
  });
}

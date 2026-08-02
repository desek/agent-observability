/**
 * @agents-index Exports a reconstructed conversation trace to MLflow's
 *   OpenTelemetry ingest endpoint: flattens the BuiltSpan tree into an OTLP/JSON
 *   trace export, POSTs it with the x-mlflow-experiment-id header (plus any
 *   configured extra headers), stays silent on failure with no retry, and tracks
 *   in-flight exports so a session shutdown can flush the last conversation.
 *
 * Why: MLflow 3.15 ingests OpenTelemetry spans directly at /v1/traces, so the
 * export needs an OTLP request, not an MLflow client or a Python environment
 * (verified against the pinned server). Hand-building the OTLP/JSON body over the
 * built-in fetch keeps the package free of an OpenTelemetry SDK dependency while
 * sending exactly the reserved span attributes MLflow reads, and keeps the wire
 * format in one auditable place. Every export carries the experiment id in a
 * header (FR8) and the trace's spans as one trace tree sharing one trace id with
 * parent links (FR7). The exporter never throws and never retries: a failed or
 * refused request is swallowed so a telemetry fault cannot break the agent loop
 * and an absent server produces no error output and no retry storm (FR16, NFR1,
 * AC-11, AC-15). It holds no conversation content of its own; it serialises the
 * trace it is handed and keeps only the pending request promise for the flush
 * (NFR3, NFR4, AC-16).
 */

import { randomBytes } from "node:crypto";

import type { BuiltSpan, BuiltTrace } from "./trace.builder.ts";

/** The header MLflow reads to group an ingested trace into an experiment (FR8). */
export const EXPERIMENT_HEADER = "x-mlflow-experiment-id";

/**
 * Configuration for one exporter instance: where to POST, which experiment id to
 * stamp, and any extra headers the user configured (FR8, FR10).
 *
 * @property endpoint - The full OTLP trace ingest URL to POST to.
 * @property experimentId - The numeric experiment id for the required header.
 * @property headers - Extra request headers applied alongside the experiment header.
 */
export interface ExporterConfig {
  endpoint: string;
  experimentId: string;
  headers: Record<string, string>;
}

/** The subset of the Fetch API the exporter needs, injectable for tests. */
export type FetchLike = (
  input: string,
  init: {
    method: string;
    headers: Record<string, string>;
    body: string;
    signal?: AbortSignal;
  },
) => Promise<{ ok: boolean; status: number }>;

/** A generated pair of OpenTelemetry ids for one span. */
interface SpanIds {
  traceId: string;
  spanId: string;
}

/** An OTLP/JSON key/value attribute with a string value. */
interface OtlpKeyValue {
  key: string;
  value: { stringValue: string };
}

/** An OTLP/JSON span. */
interface OtlpSpan {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  name: string;
  kind: number;
  startTimeUnixNano: string;
  endTimeUnixNano: string;
  attributes: OtlpKeyValue[];
}

/** OTLP span kind INTERNAL: these are reconstructed spans, not RPC boundaries. */
const SPAN_KIND_INTERNAL = 1;

/**
 * Generate a random 16-byte trace id as 32 lowercase hex characters, the
 * OTLP/JSON trace-id encoding.
 *
 * @returns A hex trace id.
 */
function newTraceId(): string {
  return randomBytes(16).toString("hex");
}

/**
 * Generate a random 8-byte span id as 16 lowercase hex characters, the OTLP/JSON
 * span-id encoding.
 *
 * @returns A hex span id.
 */
function newSpanId(): string {
  return randomBytes(8).toString("hex");
}

/**
 * Convert a BuiltSpan's pre-encoded attribute map into OTLP/JSON key/value pairs.
 * The values are already the exact strings MLflow reads (reserved `mlflow.*`
 * values JSON-encoded, `session.id` plain), so they ride verbatim as `stringValue`.
 *
 * @param attributes - The span's attribute map.
 * @returns The OTLP attribute array.
 */
function toOtlpAttributes(attributes: Record<string, string>): OtlpKeyValue[] {
  return Object.entries(attributes).map(([key, value]) => ({
    key,
    value: { stringValue: value },
  }));
}

/**
 * Flatten a BuiltSpan tree into a flat OTLP span list, assigning every span the
 * shared trace id, a fresh span id, and its parent's span id, so MLflow rebuilds
 * the same tree (root AGENT span, LLM turn spans, TOOL spans under their turn,
 * FR7). Recurses depth-first in child order.
 *
 * @param span - The BuiltSpan to flatten.
 * @param traceId - The trace id shared by every span in this trace.
 * @param parentSpanId - The parent's span id, or undefined for the root.
 * @param nowNano - The timestamp (unix nanoseconds, as a string) stamped on every
 *   span; the reconstruction carries no real per-span timing, so one session-start
 *   instant is used for start and end.
 * @param out - The accumulating flat span list, mutated in place.
 */
function flatten(
  span: BuiltSpan,
  traceId: string,
  parentSpanId: string | undefined,
  nowNano: string,
  out: OtlpSpan[],
): void {
  const spanId = newSpanId();
  const otlp: OtlpSpan = {
    traceId,
    spanId,
    name: span.name,
    kind: SPAN_KIND_INTERNAL,
    startTimeUnixNano: nowNano,
    endTimeUnixNano: nowNano,
    attributes: toOtlpAttributes(span.attributes),
  };
  if (parentSpanId !== undefined) otlp.parentSpanId = parentSpanId;
  out.push(otlp);
  for (const child of span.children) {
    flatten(child, traceId, spanId, nowNano, out);
  }
}

/**
 * Build the OTLP/JSON trace export request body for one completed trace: one
 * resourceSpans entry carrying the flattened span tree under one shared trace id.
 * Exposed for the exporter's own use and for tests that assert the payload shape.
 *
 * @param trace - The completed conversation trace.
 * @param ids - Optional pre-chosen ids, so a test can pin them; defaults to fresh
 *   random ids.
 * @returns The OTLP/JSON request body object.
 */
export function buildOtlpBody(trace: BuiltTrace, ids?: SpanIds): object {
  const traceId = ids?.traceId ?? newTraceId();
  const nowNano = (BigInt(Date.now()) * 1_000_000n).toString();
  const spans: OtlpSpan[] = [];
  flatten(trace.root, traceId, undefined, nowNano, spans);
  if (ids?.spanId && spans.length > 0) spans[0].spanId = ids.spanId;
  return {
    resourceSpans: [
      {
        resource: {
          attributes: [
            { key: "service.name", value: { stringValue: "pi-coding-agent" } },
          ],
        },
        scopeSpans: [
          {
            scope: { name: "pi-mlflow-tracing" },
            spans,
          },
        ],
      },
    ],
  };
}

/**
 * Exports completed conversation traces to MLflow's OpenTelemetry ingest endpoint.
 *
 * One instance is created per enabled session and reused across the session's
 * agent loops. {@link MlflowExporter.export} fires a POST and does not await it,
 * so the export never blocks the agent loop (NFR2); the pending promise is retained
 * only so {@link MlflowExporter.flush} can wait for it on shutdown (NFR4, AC-16).
 * Every request failure is swallowed, so an absent or throwing server produces no
 * error output, no crash, and no retry (FR16, NFR1, AC-11, AC-15).
 */
export class MlflowExporter {
  /** Resolved endpoint, experiment id, and extra headers for every export. */
  private readonly config: ExporterConfig;
  /** Fetch implementation, injectable for tests. */
  private readonly fetchImpl: FetchLike;
  /** In-flight export promises, awaited by {@link flush} and pruned on settle. */
  private readonly pending = new Set<Promise<void>>();

  /**
   * @param config - The resolved exporter configuration.
   * @param fetchImpl - Fetch implementation; defaults to the global `fetch`.
   */
  constructor(config: ExporterConfig, fetchImpl: FetchLike = fetch as unknown as FetchLike) {
    this.config = config;
    this.fetchImpl = fetchImpl;
  }

  /**
   * Serialise a completed trace to OTLP/JSON and POST it to the ingest endpoint
   * with the experiment header and any configured extra headers. Fire-and-forget:
   * the request is tracked for the flush but not awaited here, so the agent loop
   * is never blocked (NFR2). Any failure is swallowed (FR16, NFR1, AC-15).
   *
   * @param trace - The completed conversation trace to export.
   */
  export(trace: BuiltTrace): void {
    let body: string;
    try {
      body = JSON.stringify(buildOtlpBody(trace));
    } catch {
      // A non-serialisable trace is dropped rather than crashing the loop (NFR1).
      return;
    }
    const headers: Record<string, string> = {
      "content-type": "application/json",
      ...this.config.headers,
      [EXPERIMENT_HEADER]: this.config.experimentId,
    };
    const request = this.fetchImpl(this.config.endpoint, {
      method: "POST",
      headers,
      body,
    })
      .then(() => undefined)
      .catch(() => {
        // Silent on failure: an unreachable or erroring server must not print, and
        // there is no retry (FR16, NFR1, AC-11).
      });
    const tracked = request.finally(() => {
      this.pending.delete(tracked);
    });
    this.pending.add(tracked);
  }

  /**
   * Wait for every in-flight export to settle, so the last conversation of a
   * session is delivered before the process exits (NFR4, AC-16). Never rejects: a
   * failed export has already been swallowed by {@link export}.
   */
  async flush(): Promise<void> {
    await Promise.allSettled([...this.pending]);
  }
}

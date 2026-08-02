/**
 * @agents-index Default-export pi extension factory for pi-mlflow-tracing: reads
 *   the master switch from the environment, resolves the enabled decision, and
 *   returns without registering any handler, constructing any exporter, or
 *   opening any socket when disabled; when enabled it feeds pi's lifecycle events
 *   to the trace builder and registers the export and flush lifecycle anchors
 *   fail-safe so a fault can never propagate into pi.
 *
 * Why: pi loads this module's default export with its ExtensionAPI. A disabled or
 * unconfigured extension imposes zero cost and emits nothing (FR2, NFR6, AC-2),
 * which is also the state of a machine that runs only the sibling package. When
 * enabled, the factory forwards before_agent_start, turn_end, tool_execution_start,
 * tool_execution_end, and agent_end into a TraceBuilder, which reconstructs one
 * MLflow trace per agent loop (root per loop, child per turn, child per tool call)
 * and releases the conversation content when the loop's trace is taken (NFR3).
 * Phase 4 wires the MLflow exporter, the experiment resolution, and the shutdown
 * flush behind the anchors registered here. Every registration and every handler
 * body is wrapped so a telemetry fault can never crash, block, or slow pi's agent
 * loop (NFR1, AC-15).
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { TraceBuilder } from "./trace.builder.ts";

/**
 * Name of the master switch environment variable. Unset or a false value keeps
 * the extension a hard no-op; a truthy value turns conversation tracing on. Named
 * to sit alongside the sibling package's PI_OTEL_ENABLE so the two pi extensions
 * read the same way.
 */
export const ENABLE_ENV = "PI_MLFLOW_ENABLE";

/** Environment map shape (a subset of `process.env`). */
type Env = Record<string, string | undefined>;

/**
 * Interpret an environment value as a boolean opt-in flag.
 *
 * Treats unset, empty, `0`, `false`, `no`, and `off` (case-insensitively) as
 * false; any other non-empty value is true. This matches the sibling package's
 * "unset means off" opt-in posture, and conversation content is the most
 * sensitive data this project writes, so the default must be off (FR2, AC-2).
 *
 * @param value - Raw environment string, or undefined when unset.
 * @returns Whether the flag is enabled.
 */
export function parseBool(value: string | undefined): boolean {
  if (value === undefined) return false;
  const v = value.trim().toLowerCase();
  if (v === "" || v === "0" || v === "false" || v === "no" || v === "off") {
    return false;
  }
  return true;
}

/**
 * Resolve whether conversation tracing should run, reading only the master
 * switch. Unlike the sibling package there is no health-gated dynamic default:
 * because this extension writes conversation content, enabling it is always a
 * deliberate act, never inferred from a reachable server (FR2, AC-2).
 *
 * The configuration surface widens in Phase 4 (endpoint, tracking address,
 * experiment name, and extra headers, each defaulting to this project's local
 * stack); the enabled decision stays gated on this switch.
 *
 * @param env - Environment map; defaults to `process.env`.
 * @returns Whether the extension should register its handlers and export.
 */
export function resolveEnabled(env: Env = process.env): boolean {
  return parseBool(env[ENABLE_ENV]);
}

/**
 * Run a telemetry handler body fail-safe: any error is swallowed so a telemetry
 * fault can never crash, block, or slow pi's agent loop (NFR1, AC-15).
 *
 * @param fn - The handler body to execute defensively.
 */
function failSafe(fn: () => void): void {
  try {
    fn();
  } catch {
    // Telemetry must never break pi (NFR1).
  }
}

/**
 * Read pi's session identity from a handler context defensively, so a missing or
 * throwing session manager degrades to an ungrouped trace rather than a crash
 * (NFR1). The session id groups a session's traces together in MLflow (FR5).
 *
 * @param ctx - The extension context handed to an event handler.
 * @returns The session id, or undefined when it cannot be read.
 */
function sessionIdOf(ctx: ExtensionContext | undefined): string | undefined {
  try {
    return ctx?.sessionManager?.getSessionId?.();
  } catch {
    return undefined;
  }
}

/**
 * pi extension factory. Registered handlers are added only when the master
 * switch is set; the whole enabled body is defensive so a telemetry failure,
 * including a throwing host API, can never crash or block pi's agent loop
 * (NFR1, AC-15).
 *
 * The factory is async so a later phase can resolve the MLflow experiment before
 * pi's first lifecycle event without changing this contract; pi awaits the
 * returned promise before session_start, so no lifecycle event is missed.
 *
 * @param pi - The pi ExtensionAPI handed to every extension factory.
 */
export default async function (pi: ExtensionAPI): Promise<void> {
  let enabled = false;
  try {
    enabled = resolveEnabled();
  } catch {
    // A fault while reading configuration degrades to a no-op rather than
    // breaking pi startup (NFR1, NFR6).
    return;
  }

  // Off until the user turns it on: with the switch unset the extension
  // registers no handler, constructs no exporter, and opens no socket (FR2,
  // NFR6, AC-2).
  if (!enabled) return;

  // Enabled: reconstruct one MLflow trace per agent loop from pi's lifecycle
  // events. The builder holds the in-progress conversation and releases it when
  // agent_end takes the completed trace, so content never outlives the loop
  // (NFR3). Each registration is fail-safe so a throwing host API cannot
  // propagate into pi's startup, and every handler body is fail-safe so a
  // reconstruction fault cannot break the agent loop (NFR1, AC-15).
  const builder = new TraceBuilder();

  // The prompt opens a new trace; the session id groups the session's traces
  // (FR3, FR5).
  failSafe(() => {
    pi.on("before_agent_start", (event, ctx) => {
      failSafe(() => builder.beforeAgentStart(event, sessionIdOf(ctx)));
    });
  });

  // Each turn becomes an LLM span carrying the model and token usage (FR6).
  failSafe(() => {
    pi.on("turn_end", (event) => {
      failSafe(() => builder.turnEnd(event));
    });
  });

  // Each tool call becomes a TOOL span parented to the turn that issued it (FR7).
  failSafe(() => {
    pi.on("tool_execution_start", (event) => {
      failSafe(() => builder.toolExecutionStart(event));
    });
  });
  failSafe(() => {
    pi.on("tool_execution_end", (event) => {
      failSafe(() => builder.toolExecutionEnd(event));
    });
  });

  // agent_end is where one agent loop becomes one MLflow trace (FR3). Building it
  // here already releases the builder's retained conversation content (NFR3).
  // Phase 4 hands the returned trace to the MLflow exporter.
  failSafe(() => {
    pi.on("agent_end", () => {
      failSafe(() => {
        const trace = builder.agentEnd();
        // Phase 4: export `trace` to the MLflow ingest endpoint.
        void trace;
      });
    });
  });

  // session_shutdown is where a pending export is flushed so the last
  // conversation of a session is not lost (NFR4). Phase 4 wires the flush.
  failSafe(() => {
    pi.on("session_shutdown", () => {
      // Phase 4: flush any pending export before the process exits (NFR4).
    });
  });
}

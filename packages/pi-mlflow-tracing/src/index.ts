/**
 * @agents-index Default-export pi extension factory for pi-mlflow-tracing: reads
 *   the master switch from the environment, resolves the enabled decision, and
 *   returns without registering any handler, constructing any exporter, or
 *   opening any socket when disabled; when enabled it registers the export and
 *   flush lifecycle anchors fail-safe so a fault can never propagate into pi.
 *
 * Why: pi loads this module's default export with its ExtensionAPI. This is the
 * load-safe skeleton the later phases build on. A disabled or unconfigured
 * extension imposes zero cost and emits nothing (FR2, NFR6, AC-2), which is also
 * the state of a machine that runs only the sibling package. When enabled, the
 * factory owns the extension's export lifecycle: Phase 3 wires the span-tree
 * reconstruction (root per agent loop, child per turn, child per tool call) and
 * Phase 4 wires the MLflow exporter, the experiment resolution, and the shutdown
 * flush behind the anchors registered here. Every registration is wrapped so a
 * telemetry fault can never crash, block, or slow pi's agent loop (NFR1, AC-15).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

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

  // Enabled: register the export lifecycle anchors. agent_end is where one agent
  // loop becomes one exported MLflow trace (FR3), and session_shutdown is where
  // a pending export is flushed so the last conversation of a session is not
  // lost (NFR4). Phase 3 wires the span-tree reconstruction and Phase 4 wires
  // the exporter, the experiment resolution, and the flush behind these anchors;
  // the skeleton commits to the shape without yet doing either. Each
  // registration is fail-safe so a throwing host API cannot propagate into pi's
  // startup (NFR1, AC-15).
  failSafe(() => {
    pi.on("agent_end", () => {
      // Phase 4: export the reconstructed trace for the completed agent loop.
    });
  });
  failSafe(() => {
    pi.on("session_shutdown", () => {
      // Phase 4: flush any pending export before the process exits (NFR4).
    });
  });
}

/**
 * @agents-index Default-export pi extension factory for pi-mlflow-tracing: loads
 *   the configuration, and when the master switch is off registers nothing and
 *   opens no socket; when on it rejects a malformed endpoint loudly, states a
 *   non-loopback destination once, resolves the experiment name to an id (refusing
 *   to export on an unknown name and staying silent when the server is absent),
 *   then feeds pi's lifecycle events to the trace builder, exports one MLflow trace
 *   per agent loop, and flushes pending exports on session shutdown, every path
 *   fail-safe so a telemetry fault can never propagate into pi.
 *
 * Why: pi loads this module's default export with its ExtensionAPI. A disabled or
 * unconfigured extension imposes zero cost and emits nothing (FR2, NFR6, AC-2),
 * which is also the state of a machine that runs only the sibling package. When
 * enabled, the factory forwards before_agent_start, turn_end, tool_execution_start,
 * tool_execution_end, and agent_end into a TraceBuilder, which reconstructs one
 * MLflow trace per agent loop; agent_end hands the completed trace to the MLflow
 * exporter (FR3), and the builder releases the conversation content when the trace
 * is taken (NFR3). The destination is resolved once from the environment, defaulting
 * to the local stack built from the edge port (FR10, FR11); a malformed endpoint is
 * rejected with an actionable message (FR13); a non-loopback destination is stated
 * once (FR12); the experiment name is resolved to an id and the export refused
 * rather than guessed when it does not exist (FR9). An absent server is silent with
 * no retry (FR16). session_shutdown flushes so the last conversation is not lost
 * (NFR4). Every registration and every handler body is wrapped so a telemetry fault
 * can never crash, block, or slow pi's agent loop (NFR1, AC-15).
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { ENABLE_ENV, ENDPOINT_ENV, loadConfig } from "./config.env.ts";
import { MlflowExporter } from "./mlflow.exporter.ts";
import { resolveExperimentId, unknownNameMessage } from "./mlflow.experiment.ts";
import { TraceBuilder } from "./trace.builder.ts";

// Re-exported so the master-switch name has one definition (config.env.ts) yet
// stays importable from the extension entry point, where the index test reads it.
export { ENABLE_ENV } from "./config.env.ts";

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
 * Build the actionable disclosure stated once when the resolved destination is not
 * loopback, so a user who sends conversation content off the machine is told it
 * happens, told how to keep it local, and told what to verify (FR12, FR19, NFR5,
 * AC-8, AC-19).
 *
 * @param host - The non-loopback destination host.
 * @returns The disclosure message.
 */
function remoteDisclosure(host: string): string {
  return (
    `pi-mlflow-tracing: conversation content (every prompt, response, tool ` +
    `input, and tool result) will be sent to "${host}", which is not this ` +
    `machine. ` +
    `To keep it local instead, unset ${ENDPOINT_ENV} ` +
    `so the default loopback endpoint is used, or disable tracing by unsetting ` +
    `${ENABLE_ENV}. ` +
    `To confirm what is sent, open the trace in the MLflow UI on that host.`
  );
}

/**
 * pi extension factory. Handlers are registered only when the master switch is
 * set, the destination is valid, and the experiment resolves to an id. The whole
 * enabled body is defensive so a telemetry failure, including a throwing host API,
 * can never crash or block pi's agent loop (NFR1, AC-15).
 *
 * The factory is async: pi awaits the returned promise before the first lifecycle
 * event, so the experiment can be resolved to an id up front without missing any
 * event (FR9).
 *
 * @param pi - The pi ExtensionAPI handed to every extension factory.
 */
export default async function (pi: ExtensionAPI): Promise<void> {
  let config;
  try {
    config = loadConfig();
  } catch {
    // A fault while reading configuration degrades to a no-op rather than
    // breaking pi startup (NFR1, NFR6).
    return;
  }

  // Off until the user turns it on: with the switch unset the extension registers
  // no handler, constructs no exporter, and opens no socket (FR2, NFR6, AC-2).
  if (!config.enabled) return;

  // A configured endpoint that is not a valid absolute URL is rejected loudly and
  // nothing is exported; the pi session still runs normally (FR13, AC-9).
  if (config.rejection !== undefined) {
    failSafe(() => process.stderr.write(config!.rejection + "\n"));
    return;
  }

  // No destination could be built (nothing configured and no edge port to derive
  // one): stay a silent no-op rather than invent a destination (NFR6).
  if (config.endpoint === undefined || config.trackingUri === undefined) return;

  // A destination off this machine is stated once at session start (FR12, NFR5,
  // AC-8).
  if (config.remoteHost !== undefined) {
    const host = config.remoteHost;
    failSafe(() => process.stderr.write(remoteDisclosure(host) + "\n"));
  }

  // Resolve the experiment name to an id before registering anything. An unknown
  // name is refused loudly (FR9, AC-5); an unreachable server stays silent with no
  // retry and registers nothing (FR16, NFR6, AC-11).
  let experimentId: string;
  try {
    const resolution = await resolveExperimentId(config.trackingUri, config.experiment);
    if (!resolution.ok) {
      if (resolution.reason === "not-found") {
        const name = config.experiment;
        failSafe(() => process.stderr.write(unknownNameMessage(name) + "\n"));
      }
      // Either way, no export path is registered.
      return;
    }
    experimentId = resolution.id;
  } catch {
    // Any fault resolving the experiment degrades to a silent no-op (NFR1, NFR6).
    return;
  }

  // Enabled, destination valid, experiment resolved: reconstruct one MLflow trace
  // per agent loop and export it. The builder holds the in-progress conversation
  // and releases it when agent_end takes the completed trace, so content never
  // outlives the loop (NFR3). Each registration is fail-safe so a throwing host
  // API cannot propagate into pi's startup, and every handler body is fail-safe so
  // a fault cannot break the agent loop (NFR1, AC-15).
  const builder = new TraceBuilder();
  const exporter = new MlflowExporter({
    endpoint: config.endpoint,
    experimentId,
    headers: config.headers,
  });

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
  // releases the builder's retained conversation content (NFR3); the exporter POSTs
  // it fire-and-forget so the loop is never blocked (NFR2).
  failSafe(() => {
    pi.on("agent_end", () => {
      failSafe(() => {
        const trace = builder.agentEnd();
        if (trace !== undefined) exporter.export(trace);
      });
    });
  });

  // session_shutdown flushes pending exports so the last conversation of a session
  // is not lost (NFR4, AC-16). The handler awaits the flush, which never rejects.
  failSafe(() => {
    pi.on("session_shutdown", async () => {
      try {
        await exporter.flush();
      } catch {
        // A flush fault must never break session teardown (NFR1).
      }
    });
  });
}

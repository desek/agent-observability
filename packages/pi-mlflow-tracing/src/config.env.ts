/**
 * @agents-index Parses the pi-mlflow-tracing configuration from the environment:
 *   the master switch, the OTLP ingest endpoint, the tracking address, the
 *   experiment name, and any extra request headers. Every default resolves to
 *   this project's local stack, built from the edge port read from the
 *   environment (never a hard-coded port); a configured value always wins over a
 *   default; a malformed endpoint is rejected with an actionable message; and a
 *   non-loopback destination is flagged so the extension can state it once.
 *
 * Why: the extension writes conversation content, the most sensitive data this
 * project touches, so where it goes must be a single, auditable decision rather
 * than something re-derived per call site (FR8, FR9, FR10, FR11, FR12, FR13). The
 * local default keeps the common case at zero configuration for anyone running
 * this stack, while a configured endpoint serves a user whose tracking server
 * lives elsewhere. The port is read from EDGE_PORT and never written as a literal,
 * so the default follows the port the stack actually publishes (FR11). This module
 * is pure parsing with an injectable environment, so it stays side-effect free and
 * unit-testable; the exporter, the experiment resolver, and the index factory
 * consume its result.
 */

/**
 * Name of the master switch environment variable. Unset or a false value keeps
 * the extension a hard no-op; a truthy value turns conversation tracing on. Named
 * to sit alongside the sibling package's PI_OTEL_ENABLE so the two pi extensions
 * read the same way (FR2).
 */
export const ENABLE_ENV = "PI_MLFLOW_ENABLE";

/** Environment variable naming the full OTLP trace ingest endpoint (FR10). */
export const ENDPOINT_ENV = "PI_MLFLOW_ENDPOINT";

/**
 * Environment variable naming the MLflow tracking address (the REST base the
 * experiment name is resolved against, FR9/FR10).
 */
export const TRACKING_ENV = "PI_MLFLOW_TRACKING_URI";

/** Environment variable naming the experiment to write to, default `pi` (FR9). */
export const EXPERIMENT_ENV = "PI_MLFLOW_EXPERIMENT";

/**
 * Environment variable carrying extra request headers as an OTEL-style
 * comma-separated `key=value` list, applied to every export alongside the
 * experiment header (FR10).
 */
export const HEADERS_ENV = "PI_MLFLOW_HEADERS";

/**
 * Environment variable naming the loopback host port the edge proxy publishes.
 * The local defaults are built from this value; it is never hard-coded, so the
 * default follows the port the stack actually publishes (FR11).
 */
export const EDGE_PORT_ENV = "EDGE_PORT";

/** The experiment name used when none is configured (FR9). */
export const DEFAULT_EXPERIMENT = "pi";

/**
 * The prefixed path the edge proxy routes to MLflow's OpenTelemetry trace ingest
 * endpoint (added in Phase 1: `/mlflow-otlp/` is rewritten away in the backend so
 * `/mlflow-otlp/v1/traces` reaches MLflow's unprefixed `/v1/traces`). Kept here so
 * the one route the export depends on is named in one place.
 */
export const INGEST_PATH = "/mlflow-otlp/v1/traces";

/**
 * The static prefix MLflow's REST API is served under through the edge proxy. The
 * experiment resolver appends `/api/2.0/mlflow/...` to the tracking address, so
 * the local tracking default is the edge port plus this prefix.
 */
export const TRACKING_PREFIX = "/mlflow";

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
 * Whether an environment value is present and not blank.
 *
 * @param value - Raw environment string, or undefined when unset.
 * @returns True when the variable is set to a non-empty string.
 */
function isSet(value: string | undefined): boolean {
  return value !== undefined && value.trim() !== "";
}

/**
 * Parse an OTEL-style comma-separated `key=value` list into a header map, so a
 * user configures extra request headers the same way the sibling package accepts
 * OTEL_EXPORTER_OTLP_HEADERS (FR10).
 *
 * @param value - Raw list string, or undefined.
 * @returns Key/value map; empty when the input is unset or blank.
 */
export function parseHeaders(value: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!value) return out;
  for (const pair of value.split(",")) {
    const eq = pair.indexOf("=");
    if (eq === -1) continue;
    const key = pair.slice(0, eq).trim();
    const val = pair.slice(eq + 1).trim();
    if (key) out[key] = val;
  }
  return out;
}

/**
 * Whether a URL's host is a loopback address, meaning conversation content stays
 * on this machine. `localhost`, any `127.0.0.0/8` address, and IPv6 `::1` are
 * loopback; anything else is a destination off the machine (FR12, NFR5).
 *
 * @param url - A parsed URL whose hostname is inspected.
 * @returns True when the host never leaves the machine.
 */
function isLoopbackHost(url: URL): boolean {
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  return host === "localhost" || host === "::1" || /^127\./.test(host);
}

/**
 * Validate a configured endpoint as an absolute URL. Returns the parsed URL, or
 * undefined when the value is not a valid absolute URL so the caller can reject
 * it with an actionable message (FR13, AC-9).
 *
 * @param value - The raw endpoint string.
 * @returns The parsed URL, or undefined when it is not absolute and valid.
 */
function parseAbsoluteUrl(value: string): URL | undefined {
  try {
    const url = new URL(value);
    // An absolute URL must carry a scheme and a host; `new URL` accepts some
    // scheme-only strings, so require a hostname.
    return url.hostname ? url : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The resolved pi-mlflow-tracing configuration. Every field is derived once here
 * so the exporter, the experiment resolver, and the factory share one decision.
 *
 * @property enabled - Parsed master switch (unset means off, FR2).
 * @property endpoint - The resolved OTLP ingest endpoint, or undefined when no
 *   endpoint could be built (no configured value and no edge port to derive one).
 * @property endpointExplicit - Whether the endpoint came from PI_MLFLOW_ENDPOINT
 *   rather than the local default, signalling deliberate operator intent (FR10).
 * @property trackingUri - The resolved MLflow tracking address the experiment is
 *   resolved against, or undefined when none could be built (FR9, FR10).
 * @property experiment - The resolved experiment name (default `pi`, FR9).
 * @property headers - Extra request headers applied to every export (FR10).
 * @property rejection - An actionable message when the configured endpoint is not
 *   a valid absolute URL; set means export must not run (FR13, AC-9).
 * @property remoteHost - The host of a non-loopback destination, set only when
 *   conversation content will leave the machine, so the extension can state it
 *   once at session start (FR12, NFR5, AC-8).
 */
export interface MlflowConfig {
  enabled: boolean;
  endpoint: string | undefined;
  endpointExplicit: boolean;
  trackingUri: string | undefined;
  experiment: string;
  headers: Record<string, string>;
  rejection: string | undefined;
  remoteHost: string | undefined;
}

/**
 * Build the actionable message for an endpoint that is not a valid absolute URL.
 * Names the value rejected, the form expected, the variable to change, and what to
 * verify afterwards, so the reader can act rather than only diagnose (FR13, FR19,
 * AC-9, AC-19).
 *
 * @param value - The rejected endpoint value.
 * @returns The message to surface to the user.
 */
function rejectionMessage(value: string): string {
  return (
    `pi-mlflow-tracing: config.env.ts: the configured ${ENDPOINT_ENV} ` +
    `"${value}" is not a valid absolute URL, so conversation tracing is off ` +
    `and no export was attempted. ` +
    `Expected an absolute URL of the form http://host:port/path, for example ` +
    `http://localhost:<edge-port>${INGEST_PATH} for the local stack. ` +
    `To fix, set ${ENDPOINT_ENV} to such a URL, or unset it to use the local ` +
    `default built from ${EDGE_PORT_ENV}. ` +
    `After changing it, re-run a pi turn and confirm a trace appears in the ` +
    `experiment.`
  );
}

/**
 * Read the process environment (or a supplied map, for tests) into a fully
 * resolved {@link MlflowConfig}.
 *
 * Resolution order for the endpoint and the tracking address: a configured value
 * wins (FR10); otherwise a local default is built from EDGE_PORT (FR11), and when
 * EDGE_PORT is absent and nothing is configured the value is left undefined so the
 * extension stays a silent no-op rather than inventing a destination (NFR6). A
 * configured endpoint that is not a valid absolute URL sets {@link
 * MlflowConfig.rejection} and clears the endpoint (FR13). A resolved endpoint whose
 * host is not loopback sets {@link MlflowConfig.remoteHost} (FR12).
 *
 * No exporter, no socket, and no network call happens here; this is pure parsing.
 *
 * @param env - Environment map; defaults to `process.env`.
 * @returns The resolved configuration.
 */
export function loadConfig(env: Env = process.env): MlflowConfig {
  const enabled = parseBool(env[ENABLE_ENV]);
  const experiment = isSet(env[EXPERIMENT_ENV])
    ? (env[EXPERIMENT_ENV] as string).trim()
    : DEFAULT_EXPERIMENT;
  const headers = parseHeaders(env[HEADERS_ENV]);

  const port = isSet(env[EDGE_PORT_ENV]) ? (env[EDGE_PORT_ENV] as string).trim() : undefined;

  // Endpoint: a configured value wins; otherwise build the local default from the
  // edge port; otherwise leave it undefined (FR10, FR11, NFR6).
  let endpoint: string | undefined;
  let endpointExplicit = false;
  let rejection: string | undefined;
  if (isSet(env[ENDPOINT_ENV])) {
    const raw = (env[ENDPOINT_ENV] as string).trim();
    if (parseAbsoluteUrl(raw)) {
      endpoint = raw;
      endpointExplicit = true;
    } else {
      // Malformed: reject loudly and keep the endpoint unset so nothing exports
      // (FR13, AC-9).
      rejection = rejectionMessage(raw);
    }
  } else if (port !== undefined) {
    endpoint = `http://localhost:${port}${INGEST_PATH}`;
  }

  // Tracking address: a configured value wins; otherwise build the local default
  // from the edge port (FR9, FR10, FR11).
  let trackingUri: string | undefined;
  if (isSet(env[TRACKING_ENV])) {
    trackingUri = (env[TRACKING_ENV] as string).trim().replace(/\/+$/, "");
  } else if (port !== undefined) {
    trackingUri = `http://localhost:${port}${TRACKING_PREFIX}`;
  }

  // Non-loopback flag: only a valid, resolved endpoint can be classified (FR12).
  let remoteHost: string | undefined;
  if (endpoint !== undefined) {
    const url = parseAbsoluteUrl(endpoint);
    if (url && !isLoopbackHost(url)) remoteHost = url.hostname;
  }

  return {
    enabled,
    endpoint,
    endpointExplicit,
    trackingUri,
    experiment,
    headers,
    rejection,
    remoteHost,
  };
}

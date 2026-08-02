/**
 * @agents-index Parses PI_OTEL_ENABLE, the standard OTEL_* exporter/endpoint/
 *   protocol/interval/resource variables, plus Claude-Code-analogous content and
 *   cardinality opt-in flags, into a single typed config with gRPC
 *   localhost:24317 (the HAProxy edge-proxy port) defaults for the
 *   pi-opentelemetry pi extension.
 *
 * Why: every downstream module (providers, metrics/events/traces emitters) must
 * read configuration the same way and honour identical semantics to Claude
 * Code's telemetry (FR4, FR5, FR9, FR10, FR11). Centralizing the environment
 * parsing here keeps those modules pure and independently testable, and makes
 * the gRPC-24317 default and opt-in-default-off flag behaviour a single source of
 * truth rather than something re-derived per signal.
 */

/**
 * OpenTelemetry signal kinds this extension exports. Each maps to one OTLP gRPC
 * exporter and one provider.
 */
export type OtelSignal = "metrics" | "logs" | "traces";

/**
 * Per-signal exporter selection, mirroring Claude Code's
 * OTEL_{METRICS,LOGS,TRACES}_EXPORTER: `otlp` selects the OTLP gRPC exporter for
 * that signal, `none` disables the signal entirely (no silent fallback sink,
 * FR12).
 */
export type ExporterSelection = "otlp" | "none";

/**
 * Tri-state interpretation of the PI_OTEL_ENABLE master switch, needed for the
 * dynamic-default-enabled policy: an explicit on/off is honored verbatim, while
 * `unset` defers the decision to endpoint configuration and a collector health
 * probe (see {@link resolveEnabled}).
 */
export type EnableSetting = "on" | "off" | "unset";

/**
 * Resolved exporter transport for a single signal, after applying per-signal
 * overrides on top of the shared OTLP defaults.
 *
 * @property endpoint - OTLP endpoint URL the exporter targets.
 * @property protocol - OTLP protocol string (`grpc` by default).
 * @property exportIntervalMillis - Reader/processor flush interval, when set.
 */
export interface SignalExporterConfig {
  endpoint: string;
  protocol: string;
  exportIntervalMillis?: number;
}

/**
 * Content-logging opt-in flags with the same names and semantics as Claude
 * Code. Each is default-off when its variable is unset (FR9, AC-9).
 *
 * @property userPrompts - OTEL_LOG_USER_PROMPTS: include user prompt text.
 * @property assistantResponses - OTEL_LOG_ASSISTANT_RESPONSES: include response text.
 * @property toolDetails - OTEL_LOG_TOOL_DETAILS: include tool params/input.
 * @property toolContent - OTEL_LOG_TOOL_CONTENT: include tool input/output span events.
 * @property rawApiBodies - OTEL_LOG_RAW_API_BODIES: include raw provider bodies.
 */
export interface ContentFlags {
  userPrompts: boolean;
  assistantResponses: boolean;
  toolDetails: boolean;
  toolContent: boolean;
  rawApiBodies: boolean;
}

/**
 * Metric-attribute cardinality opt-in flags, matching Claude Code's
 * OTEL_METRICS_INCLUDE_* switches. Each is default-off when unset (FR10, AC-10).
 *
 * @property sessionId - OTEL_METRICS_INCLUDE_SESSION_ID.
 * @property version - OTEL_METRICS_INCLUDE_VERSION.
 * @property accountUuid - OTEL_METRICS_INCLUDE_ACCOUNT_UUID.
 * @property entrypoint - OTEL_METRICS_INCLUDE_ENTRYPOINT.
 * @property resourceAttributes - OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES.
 */
export interface CardinalityFlags {
  sessionId: boolean;
  version: boolean;
  accountUuid: boolean;
  entrypoint: boolean;
  resourceAttributes: boolean;
}

/**
 * Fully-resolved pi-opentelemetry configuration handed to the provider bootstrap and
 * the signal emitters.
 *
 * @property enabled - Parsed PI_OTEL_ENABLE truthiness (unset treated as false).
 *   Retained for reference; the effective decision comes from
 *   {@link resolveEnabled}, which layers the dynamic-default-enabled policy over
 *   {@link enableSetting} and {@link endpointExplicit}.
 * @property enableSetting - Tri-state PI_OTEL_ENABLE (on | off | unset) driving
 *   the dynamic-default-enabled policy.
 * @property endpointExplicit - Whether OTEL_EXPORTER_OTLP_ENDPOINT was set,
 *   signalling operator intent to export even without a health probe.
 * @property serviceName - service.name for the OTel Resource (default
 *   `pi-coding-agent`, FR3).
 * @property resourceAttributes - parsed OTEL_RESOURCE_ATTRIBUTES key/value pairs.
 * @property headers - parsed OTEL_EXPORTER_OTLP_HEADERS applied to every exporter.
 * @property selection - per-signal exporter selection (otlp | none).
 * @property exporters - per-signal resolved endpoint/protocol/interval.
 * @property content - content-logging opt-in flags.
 * @property cardinality - metric-attribute cardinality opt-in flags.
 */
export interface OtelParityConfig {
  enabled: boolean;
  enableSetting: EnableSetting;
  endpointExplicit: boolean;
  serviceName: string;
  resourceAttributes: Record<string, string>;
  headers: Record<string, string>;
  selection: Record<OtelSignal, ExporterSelection>;
  exporters: Record<OtelSignal, SignalExporterConfig>;
  content: ContentFlags;
  cardinality: CardinalityFlags;
}

/**
 * Default OTLP endpoint: the single HAProxy edge-proxy loopback port that fronts
 * the local LGTM stack. HAProxy accepts prior-knowledge h2c gRPC on
 * this cleartext port and routes it to Alloy's gRPC receiver, the same transport
 * Claude Code exports over.
 */
export const DEFAULT_OTLP_ENDPOINT = "http://localhost:24317";

/** Default OTLP protocol: gRPC, matching Claude Code's transport. */
export const DEFAULT_OTLP_PROTOCOL = "grpc";

/** Default service.name applied to the OTel Resource. */
export const DEFAULT_SERVICE_NAME = "pi-coding-agent";

/** Environment map shape (a subset of `process.env`). */
type Env = Record<string, string | undefined>;

/**
 * Interpret an environment value as a boolean opt-in flag.
 *
 * Treats unset, empty, `0`, `false`, `no`, and `off` (case-insensitively) as
 * false; any other non-empty value is true. This matches Claude Code's
 * "unset means off" opt-in posture (FR9/FR10/FR11).
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
 * Whether an environment value is explicitly set to a non-empty string.
 *
 * @param value - Raw environment string, or undefined when unset.
 * @returns True when the variable is present and not blank.
 */
export function isSet(value: string | undefined): boolean {
  return value !== undefined && value.trim() !== "";
}

/**
 * Interpret PI_OTEL_ENABLE as a tri-state for the dynamic-default policy: unset
 * or blank is `unset` (defer), otherwise the same truthiness as {@link parseBool}
 * collapses to `on` or `off`.
 *
 * @param value - Raw PI_OTEL_ENABLE value, or undefined when unset.
 * @returns The tri-state enable setting.
 */
export function parseEnableSetting(value: string | undefined): EnableSetting {
  if (!isSet(value)) return "unset";
  return parseBool(value) ? "on" : "off";
}

/**
 * Parse an OTEL-style comma-separated `key=value` list (used by both
 * OTEL_RESOURCE_ATTRIBUTES and OTEL_EXPORTER_OTLP_HEADERS).
 *
 * @param value - Raw list string, or undefined.
 * @returns Key/value map; empty when the input is unset or blank.
 */
export function parseKeyValueList(value: string | undefined): Record<string, string> {
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
 * Parse a positive-integer millisecond interval from an environment value.
 *
 * @param value - Raw environment string, or undefined.
 * @returns The parsed interval, or undefined when unset or invalid so the SDK
 *   default applies.
 */
function parseInterval(value: string | undefined): number | undefined {
  if (value === undefined || value.trim() === "") return undefined;
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

/**
 * First defined, non-empty value among the provided candidates, else the
 * fallback. Used to layer per-signal overrides over shared OTLP defaults.
 *
 * @param fallback - Value returned when no candidate is set.
 * @param candidates - Candidate environment values in precedence order.
 * @returns The resolved string.
 */
function firstSet(fallback: string, ...candidates: (string | undefined)[]): string {
  for (const c of candidates) {
    if (c !== undefined && c.trim() !== "") return c.trim();
  }
  return fallback;
}

/**
 * Resolve the exporter selection for a single signal from its per-signal
 * OTEL_*_EXPORTER variable. Anything other than `none` resolves to `otlp`.
 *
 * @param value - Raw per-signal exporter variable.
 * @returns `none` when explicitly disabled, otherwise `otlp`.
 */
function parseSelection(value: string | undefined): ExporterSelection {
  return value !== undefined && value.trim().toLowerCase() === "none" ? "none" : "otlp";
}

/**
 * Build the resolved transport config for one signal, layering the per-signal
 * OTEL_EXPORTER_OTLP_{SIGNAL}_{ENDPOINT,PROTOCOL} overrides and the per-signal
 * export interval over the shared OTLP defaults (FR4, FR5).
 *
 * @param env - Environment map.
 * @param sharedEndpoint - Shared OTEL_EXPORTER_OTLP_ENDPOINT (or default).
 * @param sharedProtocol - Shared OTEL_EXPORTER_OTLP_PROTOCOL (or default).
 * @param endpointKey - Per-signal endpoint variable name.
 * @param protocolKey - Per-signal protocol variable name.
 * @param intervalKey - Per-signal export-interval variable name.
 * @returns The resolved per-signal exporter config.
 */
function resolveSignal(
  env: Env,
  sharedEndpoint: string,
  sharedProtocol: string,
  endpointKey: string,
  protocolKey: string,
  intervalKey: string,
): SignalExporterConfig {
  return {
    endpoint: firstSet(sharedEndpoint, env[endpointKey]),
    protocol: firstSet(sharedProtocol, env[protocolKey]),
    exportIntervalMillis: parseInterval(env[intervalKey]),
  };
}

/**
 * Read the process environment (or a supplied map, for tests) into a fully
 * resolved {@link OtelParityConfig}.
 *
 * All defaults follow Claude Code parity: gRPC transport on
 * http://localhost:24317 (the HAProxy edge-proxy port) (FR4),
 * service.name `pi-coding-agent` (FR3), and every content/cardinality
 * flag off-when-unset (FR9, FR10). No exporter is constructed here; this is pure
 * parsing so it stays testable and side-effect free.
 *
 * @param env - Environment map; defaults to `process.env`.
 * @returns The resolved configuration.
 */
/**
 * Resolve whether telemetry should actually run, implementing the
 * dynamic-default-enabled policy:
 *
 * - PI_OTEL_ENABLE explicitly on or off is honored verbatim, with no probe.
 * - Unset with an explicit OTEL_EXPORTER_OTLP_ENDPOINT enables export: the
 *   operator configured a target, so intent is assumed.
 * - Unset with no endpoint enables export only when the local collector is
 *   healthy, so a machine without the observability stack running silently
 *   exports nothing instead of emitting to a dead endpoint.
 *
 * The health probe is injected so this policy stays pure and unit-testable; the
 * factory passes {@link probeAlloyHealthy}.
 *
 * @param config - Resolved configuration (supplies enableSetting and endpointExplicit).
 * @param probe - Async collector-health probe, invoked only in the dynamic case.
 * @returns Whether the extension should initialize exporters.
 */
export async function resolveEnabled(
  config: OtelParityConfig,
  probe: () => Promise<boolean>,
): Promise<boolean> {
  if (config.enableSetting === "on") return true;
  if (config.enableSetting === "off") return false;
  if (config.endpointExplicit) return true;
  return probe();
}

export function loadConfig(env: Env = process.env): OtelParityConfig {
  const sharedEndpoint = firstSet(
    DEFAULT_OTLP_ENDPOINT,
    env.OTEL_EXPORTER_OTLP_ENDPOINT,
  );
  const sharedProtocol = firstSet(
    DEFAULT_OTLP_PROTOCOL,
    env.OTEL_EXPORTER_OTLP_PROTOCOL,
  );

  return {
    enabled: parseBool(env.PI_OTEL_ENABLE),
    enableSetting: parseEnableSetting(env.PI_OTEL_ENABLE),
    endpointExplicit: isSet(env.OTEL_EXPORTER_OTLP_ENDPOINT),
    serviceName: firstSet(DEFAULT_SERVICE_NAME, env.OTEL_SERVICE_NAME),
    resourceAttributes: parseKeyValueList(env.OTEL_RESOURCE_ATTRIBUTES),
    headers: parseKeyValueList(env.OTEL_EXPORTER_OTLP_HEADERS),
    selection: {
      metrics: parseSelection(env.OTEL_METRICS_EXPORTER),
      logs: parseSelection(env.OTEL_LOGS_EXPORTER),
      traces: parseSelection(env.OTEL_TRACES_EXPORTER),
    },
    exporters: {
      metrics: resolveSignal(
        env,
        sharedEndpoint,
        sharedProtocol,
        "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
        "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL",
        "OTEL_METRIC_EXPORT_INTERVAL",
      ),
      logs: resolveSignal(
        env,
        sharedEndpoint,
        sharedProtocol,
        "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
        "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL",
        "OTEL_LOGS_EXPORT_INTERVAL",
      ),
      traces: resolveSignal(
        env,
        sharedEndpoint,
        sharedProtocol,
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL",
        "OTEL_TRACES_EXPORT_INTERVAL",
      ),
    },
    content: {
      userPrompts: parseBool(env.OTEL_LOG_USER_PROMPTS),
      assistantResponses: parseBool(env.OTEL_LOG_ASSISTANT_RESPONSES),
      toolDetails: parseBool(env.OTEL_LOG_TOOL_DETAILS),
      toolContent: parseBool(env.OTEL_LOG_TOOL_CONTENT),
      rawApiBodies: parseBool(env.OTEL_LOG_RAW_API_BODIES),
    },
    cardinality: {
      sessionId: parseBool(env.OTEL_METRICS_INCLUDE_SESSION_ID),
      version: parseBool(env.OTEL_METRICS_INCLUDE_VERSION),
      accountUuid: parseBool(env.OTEL_METRICS_INCLUDE_ACCOUNT_UUID),
      entrypoint: parseBool(env.OTEL_METRICS_INCLUDE_ENTRYPOINT),
      resourceAttributes: parseBool(env.OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES),
    },
  };
}

/**
 * @agents-index Builds the standard, cardinality-gated attribute set shared by the
 *   pi.* metric instruments, applying Claude-Code-equivalent OTEL_METRICS_INCLUDE_*
 *   opt-in semantics so high-cardinality dimensions are attached only when their
 *   flag is enabled.
 *
 * Why: Claude Code lets operators trade cardinality for detail via the
 * OTEL_METRICS_INCLUDE_* switches (session id, app version, account uuid,
 * entrypoint, and the promoted resource attributes). The metrics emitter must
 * apply identical gating (FR10, AC-10) to every instrument, so that logic lives
 * in one pure, testable place here rather than being re-derived per instrument.
 * Values the current pi lifecycle does not surface (for example session id) are
 * simply omitted; the gate still governs whether they would be attached, which is
 * the behaviour parity requires.
 */

import type { Attributes } from "@opentelemetry/api";

import type { OtelParityConfig } from "./config.env.ts";

/**
 * Optional identity/context values a caller can offer for cardinality-gated
 * attributes. Each is attached to metric attributes only when both the value is
 * present and its OTEL_METRICS_INCLUDE_* flag is enabled.
 *
 * @property sessionId - Current pi session identifier (OTEL_METRICS_INCLUDE_SESSION_ID).
 * @property version - pi/agent version string (OTEL_METRICS_INCLUDE_VERSION).
 * @property accountUuid - Account/user UUID (OTEL_METRICS_INCLUDE_ACCOUNT_UUID).
 * @property entrypoint - Invocation entrypoint, e.g. `cli` (OTEL_METRICS_INCLUDE_ENTRYPOINT).
 */
export interface StandardAttributeContext {
  sessionId?: string;
  version?: string;
  accountUuid?: string;
  entrypoint?: string;
}

/** Attribute key for the session id dimension. */
const ATTR_SESSION_ID = "session.id";
/** Attribute key for the app/agent version dimension. */
const ATTR_APP_VERSION = "app.version";
/** Attribute key for the account uuid dimension. */
const ATTR_ACCOUNT_UUID = "user.account_uuid";
/** Attribute key for the entrypoint dimension. */
const ATTR_ENTRYPOINT = "entrypoint";

/**
 * Build the cardinality-gated standard attributes for a metric record.
 *
 * Each candidate dimension is included only when its OTEL_METRICS_INCLUDE_* flag
 * is on (FR10, AC-10): session id, version, account uuid, and entrypoint from the
 * supplied context, plus the promoted OTEL_RESOURCE_ATTRIBUTES when
 * OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES is enabled. A disabled flag, or an
 * absent value, leaves the dimension off.
 *
 * @param config - Resolved pi-opentelemetry configuration (supplies the cardinality flags).
 * @param ctx - Optional identity/context values to gate.
 * @returns The attribute map to merge into a metric record.
 */
export function buildStandardAttributes(
  config: OtelParityConfig,
  ctx: StandardAttributeContext = {},
): Attributes {
  const attrs: Attributes = {};
  const gate = config.cardinality;

  if (gate.sessionId && ctx.sessionId !== undefined) attrs[ATTR_SESSION_ID] = ctx.sessionId;
  if (gate.version && ctx.version !== undefined) attrs[ATTR_APP_VERSION] = ctx.version;
  if (gate.accountUuid && ctx.accountUuid !== undefined) {
    attrs[ATTR_ACCOUNT_UUID] = ctx.accountUuid;
  }
  if (gate.entrypoint && ctx.entrypoint !== undefined) attrs[ATTR_ENTRYPOINT] = ctx.entrypoint;

  if (gate.resourceAttributes) {
    for (const [key, value] of Object.entries(config.resourceAttributes)) {
      attrs[key] = value;
    }
  }

  return attrs;
}

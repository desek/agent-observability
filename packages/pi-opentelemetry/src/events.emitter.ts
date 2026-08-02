/**
 * @agents-index Emits the pi.* OTLP log events (user_prompt, assistant_response,
 *   api_request, api_refusal, tool_result, tool_decision, api_error, raw request
 *   and response bodies, and compaction) from pi lifecycle events, with each
 *   content-bearing field gated behind the Claude-Code-equivalent OTEL_LOG_*
 *   opt-in flag; the event name is the log body and all fields ride as attributes.
 *
 * Why: Claude Code emits roughly thirty structured log events; parity (FR7) means
 * pi must emit the same events under the pi.* namespace, keyed the same way so the
 * Alloy readable-log-line transform (Phase 5) can rewrite each body. This module
 * owns the Logger and the content gates so the index factory only forwards events
 * and so every emit path shares one gating implementation (FR9). Fields pi's
 * lifecycle does not surface are simply omitted; the event shape still matches
 * Claude Code's. All emit methods are best-effort and expect the caller to wrap
 * them fail-safe (NFR2).
 */

import { SeverityNumber, type Logger } from "@opentelemetry/api-logs";
import type { LoggerProvider } from "@opentelemetry/sdk-logs";

import type { OtelParityConfig } from "./config.env.ts";
import { INSTRUMENTATION_SCOPE } from "./otel.providers.ts";

/** pi.* log event body values, mirroring Claude Code's event names one-for-one. */
const EVENT = {
  userPrompt: "pi.user_prompt",
  assistantResponse: "pi.assistant_response",
  apiRequest: "pi.api_request",
  apiRefusal: "pi.api_refusal",
  toolResult: "pi.tool_result",
  toolDecision: "pi.tool_decision",
  apiError: "pi.api_error",
  apiRequestBody: "pi.api_request_body",
  apiResponseBody: "pi.api_response_body",
  compaction: "pi.compaction",
} as const;

/**
 * Loosely-typed view of a finalized assistant message. pi's event types are not
 * resolvable in this package, so the fields the emitter reads are declared
 * structurally and accessed defensively.
 *
 * @property role - Message role; only `assistant` messages produce response and
 *   api_request events.
 * @property model - Model identifier that produced the message.
 * @property id - Provider response identifier (response_id attribute).
 * @property content - Message content, either a plain string or an array of
 *   content parts each optionally carrying `text`.
 * @property stopReason - Provider stop/finish reason; a refusal value triggers
 *   the api_refusal event.
 * @property usage - Token usage and cost for the assistant turn.
 */
interface AssistantMessage {
  role?: string;
  model?: string;
  id?: string;
  content?: string | Array<{ text?: string }>;
  stopReason?: string;
  finishReason?: string;
  usage?: {
    input?: number;
    output?: number;
    cacheRead?: number;
    cacheWrite?: number;
    cost?: { total?: number };
  };
}

/**
 * Extract plain text from a pi message content field that may be a string or an
 * array of content parts.
 *
 * @param content - The message content, string, part array, or undefined.
 * @returns Concatenated text, or undefined when no text is present.
 */
function extractText(content: AssistantMessage["content"]): string | undefined {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const text = content.map((part) => part?.text ?? "").join("");
    return text.length > 0 ? text : undefined;
  }
  return undefined;
}

/**
 * Byte-ish size of an arbitrary tool input/output value, for the *_size
 * attributes. Serializes to JSON and returns its length; non-serializable values
 * yield undefined.
 *
 * @param value - The value to size.
 * @returns The serialized length, or undefined when it cannot be serialized.
 */
function jsonSize(value: unknown): number | undefined {
  if (value === undefined) return undefined;
  try {
    return JSON.stringify(value)?.length;
  } catch {
    return undefined;
  }
}

/**
 * Serialize a value for a raw-body attribute, truncating defensively is left to
 * the collector; here we only guarantee a string or undefined.
 *
 * @param value - The raw request or response payload.
 * @returns A JSON string, or undefined when it cannot be serialized.
 */
function serializeBody(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}

/** Attribute map value type accepted by the OTLP log record. */
type Attrs = Record<string, string | number | boolean>;

/**
 * Assign a value into an attribute map only when it is defined, keeping optional
 * fields absent (rather than null) so the Alloy transform's `!= nil` guards work.
 *
 * @param attrs - The attribute map to mutate.
 * @param key - Attribute key.
 * @param value - Candidate value; skipped when undefined.
 */
function put(attrs: Attrs, key: string, value: string | number | boolean | undefined): void {
  if (value !== undefined) attrs[key] = value;
}

/**
 * Owns the pi.* Logger and emits the parity log events from pi lifecycle events,
 * applying the OTEL_LOG_* content gates. Constructed only when the logs signal is
 * enabled (a LoggerProvider exists).
 */
export class EventsEmitter {
  private readonly config: OtelParityConfig;
  private readonly logger: Logger;

  /**
   * @param loggerProvider - The initialized LoggerProvider from otel.providers.
   * @param config - Resolved pi-opentelemetry configuration (supplies content gates).
   */
  constructor(loggerProvider: LoggerProvider, config: OtelParityConfig) {
    this.config = config;
    this.logger = loggerProvider.getLogger(INSTRUMENTATION_SCOPE);
  }

  /**
   * Emit one pi.* log record: the event name is the body (so the Alloy transform
   * can key on it) and all fields ride as attributes.
   *
   * @param name - The pi.* event name used as the log body.
   * @param attributes - The structured fields for the event.
   * @param severity - Severity number, INFO by default.
   */
  private emit(name: string, attributes: Attrs, severity: SeverityNumber = SeverityNumber.INFO): void {
    this.logger.emit({
      body: name,
      eventName: name,
      severityNumber: severity,
      severityText: SeverityNumber[severity],
      attributes,
    });
  }

  /**
   * Emit pi.user_prompt from before_agent_start. `prompt_length` is always
   * recorded; the `prompt` text is included only when OTEL_LOG_USER_PROMPTS is on.
   *
   * @param event - The before_agent_start lifecycle event.
   */
  userPrompt(event: { prompt?: unknown }): void {
    const prompt = typeof event.prompt === "string" ? event.prompt : undefined;
    const attrs: Attrs = {};
    put(attrs, "prompt_length", prompt?.length);
    if (this.config.content.userPrompts) put(attrs, "prompt", prompt);
    this.emit(EVENT.userPrompt, attrs);
  }

  /**
   * Emit pi.assistant_response, pi.api_request, pi.api_response_body (gated
   * behind OTEL_LOG_RAW_API_BODIES; message_end is the earliest hook where the
   * finalized response is available, since after_provider_response carries no
   * body), and pi.api_refusal (when the stop reason indicates a refusal) from a
   * finalized assistant message_end. Non-assistant messages are ignored, as are
   * assistant messages with no text content (interim tool-call turns) for
   * assistant_response, so every emitted assistant_response carries content.
   * Response text is gated behind OTEL_LOG_ASSISTANT_RESPONSES;
   * `response_length`, `model`, and the api_request token and cost fields are
   * always recorded when present.
   *
   * @param event - The message_end lifecycle event.
   */
  messageEnd(event: { message?: unknown; durationMs?: number }): void {
    const message = event.message as AssistantMessage | undefined;
    if (!message || message.role !== "assistant") return;

    if (this.config.content.rawApiBodies) {
      const bodyAttrs: Attrs = {};
      put(bodyAttrs, "model", message.model);
      put(bodyAttrs, "body", serializeBody(message));
      this.emit(EVENT.apiResponseBody, bodyAttrs);
    }

    const response = extractText(message.content);
    if (response) {
      const responseAttrs: Attrs = {};
      put(responseAttrs, "response_length", response.length);
      put(responseAttrs, "model", message.model);
      if (this.config.content.assistantResponses) put(responseAttrs, "response", response);
      this.emit(EVENT.assistantResponse, responseAttrs);
    }

    const usage = message.usage;
    const apiAttrs: Attrs = {};
    put(apiAttrs, "model", message.model);
    put(apiAttrs, "response_id", message.id);
    put(apiAttrs, "duration_ms", event.durationMs);
    put(apiAttrs, "input_tokens", usage?.input);
    put(apiAttrs, "output_tokens", usage?.output);
    put(apiAttrs, "cache_read_tokens", usage?.cacheRead);
    put(apiAttrs, "cache_creation_tokens", usage?.cacheWrite);
    put(apiAttrs, "cost_usd", usage?.cost?.total);
    this.emit(EVENT.apiRequest, apiAttrs);

    const stop = message.stopReason ?? message.finishReason;
    if (stop !== undefined && /refus/i.test(stop)) {
      const refusalAttrs: Attrs = {};
      put(refusalAttrs, "model", message.model);
      put(refusalAttrs, "finish_reason", stop);
      this.emit(EVENT.apiRefusal, refusalAttrs, SeverityNumber.WARN);
    }
  }

  /**
   * Emit pi.tool_result from tool_result. `tool_name`, `success`, `duration_ms`,
   * and input/output sizes are always recorded; `tool_input`/`tool_parameters`
   * are included only when OTEL_LOG_TOOL_DETAILS is on.
   *
   * @param event - The tool_result lifecycle event.
   */
  toolResult(event: {
    toolName?: string;
    input?: unknown;
    isError?: boolean;
    details?: { durationMs?: number };
    durationMs?: number;
    output?: unknown;
  }): void {
    const attrs: Attrs = {};
    put(attrs, "tool_name", event.toolName);
    put(attrs, "success", event.isError === undefined ? undefined : !event.isError);
    put(attrs, "duration_ms", event.details?.durationMs ?? event.durationMs);
    put(attrs, "input_size", jsonSize(event.input));
    put(attrs, "output_size", jsonSize(event.output));
    if (this.config.content.toolDetails) {
      put(attrs, "tool_parameters", serializeBody(event.input));
    }
    this.emit(EVENT.toolResult, attrs);
  }

  /**
   * Emit pi.tool_decision from tool_call: whether a tool invocation was accepted
   * or rejected and the source of the decision.
   *
   * @param event - The tool_call lifecycle event.
   */
  toolDecision(event: { toolName?: string; decision?: string; source?: string }): void {
    const attrs: Attrs = {};
    put(attrs, "tool_name", event.toolName);
    put(attrs, "decision", event.decision);
    put(attrs, "source", event.source);
    this.emit(EVENT.toolDecision, attrs);
  }

  /**
   * Emit pi.api_request_body from before_provider_request, gated entirely behind
   * OTEL_LOG_RAW_API_BODIES. When the flag is off nothing is emitted.
   *
   * pi's BeforeProviderRequestEvent carries the outbound request as `payload`
   * (not `body`/`request`); the model id, when present, lives inside that
   * payload rather than on the event.
   *
   * @param event - The before_provider_request lifecycle event.
   */
  apiRequestBody(event: { payload?: unknown; model?: string; body?: unknown; request?: unknown }): void {
    if (!this.config.content.rawApiBodies) return;
    const payload = event.payload ?? event.body ?? event.request;
    const payloadModel = (payload as { model?: unknown } | undefined)?.model;
    const attrs: Attrs = {};
    put(attrs, "model", event.model ?? (typeof payloadModel === "string" ? payloadModel : undefined));
    put(attrs, "body", serializeBody(payload));
    this.emit(EVENT.apiRequestBody, attrs);
  }

  /**
   * Emit pi.api_error from after_provider_response when the response carries an
   * error status (>= 400) or error payload.
   *
   * Note: pi's AfterProviderResponseEvent exposes only `status` and `headers`,
   * never the response body, so pi.api_response_body is NOT emitted here; it is
   * emitted from message_end (see messageEnd), where the finalized assistant
   * message is available.
   *
   * @param event - The after_provider_response lifecycle event.
   */
  afterProviderResponse(event: {
    model?: string;
    statusCode?: number;
    status?: number;
    error?: unknown;
    durationMs?: number;
    attempt?: number;
  }): void {
    const status = event.statusCode ?? event.status;
    const hasError = (status !== undefined && status >= 400) || event.error !== undefined;
    if (!hasError) return;

    const errorAttrs: Attrs = {};
    put(errorAttrs, "model", event.model);
    put(errorAttrs, "status_code", status);
    put(errorAttrs, "error", errorMessage(event.error));
    put(errorAttrs, "duration_ms", event.durationMs);
    put(errorAttrs, "attempt", event.attempt);
    this.emit(EVENT.apiError, errorAttrs, SeverityNumber.ERROR);
  }

  /**
   * Emit pi.compaction from session_compact: the context-window compaction
   * outcome, with its trigger and pre/post token counts.
   *
   * @param event - The session_compact lifecycle event.
   */
  compaction(event: {
    trigger?: string;
    reason?: string;
    success?: boolean;
    preTokens?: number;
    postTokens?: number;
  }): void {
    const attrs: Attrs = {};
    put(attrs, "trigger", event.trigger ?? event.reason);
    put(attrs, "success", event.success);
    put(attrs, "pre_tokens", event.preTokens);
    put(attrs, "post_tokens", event.postTokens);
    this.emit(EVENT.compaction, attrs);
  }
}

/**
 * Reduce an arbitrary error value to a human-readable message string.
 *
 * @param error - Error, string, or structured error payload.
 * @returns A message string, or undefined when there is nothing to report.
 */
function errorMessage(error: unknown): string | undefined {
  if (error === undefined || error === null) return undefined;
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  const maybe = error as { message?: unknown };
  if (typeof maybe.message === "string") return maybe.message;
  return serializeBody(error);
}

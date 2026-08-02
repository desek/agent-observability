/**
 * @agents-index Opens and closes the pi.* span hierarchy (pi.interaction wrapping
 *   pi.llm_request and pi.tool, the latter with a pi.tool.execution child) from pi
 *   lifecycle events, carrying gen_ai.* and pi.* attributes with tool and prompt
 *   content gated behind the Claude-Code-equivalent OTEL_LOG_* opt-in flags.
 *
 * Why: Claude Code's enhanced-telemetry beta emits a four-level span tree per user
 * prompt; parity (FR8) means pi must emit the same shape under the pi.* namespace.
 * pi's lifecycle events fire asynchronously rather than on one synchronous call
 * stack, so the emitter cannot rely on the ambient OTel context to nest spans;
 * instead it holds the open parent spans and builds an explicit child context for
 * each new span. This module owns the Tracer and the span state machine so the
 * index factory only forwards events, and so parent-child nesting and content
 * gating (FR9) live in one place. Concurrent tool executions are keyed by their
 * toolCallId. All methods are best-effort and expect the caller (index factory)
 * to wrap them fail-safe (NFR2); on agent_end any spans still open are closed
 * defensively so a missed end event cannot leak a span.
 */

import {
  context,
  trace,
  SpanStatusCode,
  type Context,
  type Span,
  type Tracer,
} from "@opentelemetry/api";

import type { OtelParityConfig } from "./config.env.ts";

/** pi.* span name values, mirroring Claude Code's span names one-for-one. */
const SPAN = {
  interaction: "pi.interaction",
  llmRequest: "pi.llm_request",
  tool: "pi.tool",
  toolExecution: "pi.tool.execution",
} as const;

/**
 * Loosely-typed view of a finalized assistant message. pi's AgentMessage union is
 * not re-declared here; the emitter reads only the fields it stamps onto the
 * pi.llm_request span and accesses them defensively.
 *
 * @property role - Message role; only `assistant` messages carry llm_request data.
 * @property model - Model identifier that produced the message (gen_ai.request.model).
 * @property id - Provider response identifier (gen_ai.response.id).
 * @property stopReason - Provider stop/finish reason (gen_ai.response.finish_reasons).
 * @property finishReason - Alternate finish-reason field name.
 * @property usage - Token usage for the assistant turn.
 */
interface AssistantMessage {
  role?: string;
  model?: string;
  id?: string;
  stopReason?: string;
  finishReason?: string;
  usage?: {
    input?: number;
    output?: number;
    cacheRead?: number;
    cacheWrite?: number;
  };
}

/** The pair of spans tracked for one in-flight tool execution. */
interface ToolSpans {
  /** The outer pi.tool span. */
  toolSpan: Span;
  /** The inner pi.tool.execution span. */
  execSpan: Span;
  /** Wall-clock start time (ms) for duration_ms. */
  startMs: number;
}

/**
 * Set a span attribute only when the value is defined, keeping optional fields
 * off the span rather than recording undefined/null.
 *
 * @param span - The span to annotate.
 * @param key - Attribute key.
 * @param value - Candidate value; skipped when undefined.
 */
function attr(span: Span, key: string, value: string | number | boolean | undefined): void {
  if (value !== undefined) span.setAttribute(key, value);
}

/**
 * Serialize a tool input/output value for a span event body. Strings pass through;
 * other values are JSON-encoded; non-serializable values yield undefined.
 *
 * @param value - The value to serialize.
 * @returns A string, or undefined when it cannot be serialized.
 */
function serialize(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}

/**
 * Owns the pi.* Tracer and drives the span hierarchy from pi lifecycle events,
 * applying the OTEL_LOG_* content gates. Constructed only when the traces signal
 * is enabled (a Tracer exists). Spans are nested via an explicit child context
 * because pi's events do not share one synchronous call stack.
 */
export class TracesEmitter {
  private readonly config: OtelParityConfig;
  private readonly tracer: Tracer;

  /** The open pi.interaction span for the current agent loop, if any. */
  private interactionSpan: Span | undefined;
  /** Wall-clock start (ms) of the current interaction, for duration_ms. */
  private interactionStartMs = 0;
  /** Prompt captured from before_agent_start, applied when the interaction opens. */
  private pendingPrompt: string | undefined;

  /** The open pi.llm_request span for the in-flight provider request, if any. */
  private llmSpan: Span | undefined;
  /** Wall-clock start (ms) of the in-flight provider request, for duration_ms. */
  private llmStartMs = 0;

  /** In-flight tool executions keyed by toolCallId, for correct concurrent nesting. */
  private readonly tools = new Map<string, ToolSpans>();

  /**
   * @param tracer - The initialized Tracer from otel.providers.
   * @param config - Resolved pi-opentelemetry configuration (supplies content gates).
   */
  constructor(tracer: Tracer, config: OtelParityConfig) {
    this.config = config;
    this.tracer = tracer;
  }

  /**
   * Build a child context rooted at a parent span, or the active context when
   * there is no parent. Explicit nesting is required because pi's lifecycle
   * events fire across asynchronous boundaries rather than one call stack.
   *
   * @param parent - The parent span, or undefined for a root span.
   * @returns The context to pass to tracer.startSpan for a child of `parent`.
   */
  private childOf(parent: Span | undefined): Context {
    const base = context.active();
    return parent ? trace.setSpan(base, parent) : base;
  }

  /**
   * Capture the raw user prompt from before_agent_start so it can be stamped onto
   * the pi.interaction span (gated behind OTEL_LOG_USER_PROMPTS) once the agent
   * loop actually starts.
   *
   * @param event - The before_agent_start lifecycle event.
   */
  beforeAgentStart(event: { prompt?: unknown }): void {
    this.pendingPrompt = typeof event.prompt === "string" ? event.prompt : undefined;
  }

  /**
   * Open the pi.interaction span wrapping one user prompt (agent_start). The
   * prompt text rides as an attribute only when OTEL_LOG_USER_PROMPTS is on
   * (FR9); prompt_length is always recorded when a prompt was captured.
   */
  agentStart(): void {
    // Defensive: a prior interaction that never saw agent_end is closed first so
    // spans cannot leak across loops.
    this.closeInteraction();
    this.interactionStartMs = Date.now();
    const span = this.tracer.startSpan(SPAN.interaction, {}, this.childOf(undefined));
    const prompt = this.pendingPrompt;
    attr(span, "prompt_length", prompt?.length);
    if (this.config.content.userPrompts) attr(span, "user_prompt", prompt);
    this.pendingPrompt = undefined;
    this.interactionSpan = span;
  }

  /**
   * Close the pi.interaction span (agent_end), first closing any llm_request or
   * tool spans still open so a missed end event cannot leak a span.
   */
  agentEnd(): void {
    this.closeInteraction();
  }

  /**
   * Open a pi.llm_request span as a child of the current interaction on
   * before_provider_request. A previous unfinished llm span (should not happen in
   * a serial loop) is ended defensively first.
   */
  llmRequestStart(): void {
    if (this.llmSpan) {
      this.llmSpan.end();
      this.llmSpan = undefined;
    }
    this.llmStartMs = Date.now();
    this.llmSpan = this.tracer.startSpan(
      SPAN.llmRequest,
      {},
      this.childOf(this.interactionSpan),
    );
  }

  /**
   * Stamp gen_ai.* and token attributes onto the open pi.llm_request span from a
   * finalized assistant message and close it (message_end). Non-assistant
   * messages are ignored; if no llm span is open the call is a no-op.
   *
   * @param event - The message_end lifecycle event.
   */
  messageEnd(event: { message?: unknown }): void {
    const message = event.message as AssistantMessage | undefined;
    if (!message || message.role !== "assistant") return;
    const span = this.llmSpan;
    if (!span) return;

    attr(span, "gen_ai.system", "pi");
    attr(span, "gen_ai.request.model", message.model);
    attr(span, "model", message.model);
    attr(span, "gen_ai.response.id", message.id);
    attr(span, "response_id", message.id);

    const usage = message.usage;
    attr(span, "gen_ai.usage.input_tokens", usage?.input);
    attr(span, "gen_ai.usage.output_tokens", usage?.output);
    attr(span, "input_tokens", usage?.input);
    attr(span, "output_tokens", usage?.output);
    attr(span, "cache_read_tokens", usage?.cacheRead);
    attr(span, "cache_creation_tokens", usage?.cacheWrite);

    const finish = message.stopReason ?? message.finishReason;
    if (finish !== undefined) {
      span.setAttribute("gen_ai.response.finish_reasons", [finish]);
      attr(span, "finish_reasons", finish);
    }

    attr(span, "duration_ms", Date.now() - this.llmStartMs);
    span.end();
    this.llmSpan = undefined;
  }

  /**
   * Open the pi.tool span and its pi.tool.execution child on tool_execution_start,
   * keyed by toolCallId. The tool input rides as a span event only when
   * OTEL_LOG_TOOL_CONTENT is on (FR9).
   *
   * @param event - The tool_execution_start lifecycle event.
   */
  toolExecutionStart(event: { toolCallId?: string; toolName?: string; args?: unknown }): void {
    const id = event.toolCallId;
    if (id === undefined) return;

    const toolSpan = this.tracer.startSpan(SPAN.tool, {}, this.childOf(this.interactionSpan));
    attr(toolSpan, "tool_name", event.toolName);

    const execSpan = this.tracer.startSpan(
      SPAN.toolExecution,
      {},
      this.childOf(toolSpan),
    );
    attr(execSpan, "tool_name", event.toolName);

    if (this.config.content.toolContent) {
      const input = serialize(event.args);
      if (input !== undefined) toolSpan.addEvent("tool.input", { "tool.input": input });
    }

    this.tools.set(id, { toolSpan, execSpan, startMs: Date.now() });
  }

  /**
   * Close the pi.tool.execution and pi.tool spans on tool_execution_end, recording
   * success and (gated behind OTEL_LOG_TOOL_DETAILS) any error, plus a tool.output
   * span event gated behind OTEL_LOG_TOOL_CONTENT (FR9).
   *
   * @param event - The tool_execution_end lifecycle event.
   */
  toolExecutionEnd(event: {
    toolCallId?: string;
    isError?: boolean;
    result?: unknown;
  }): void {
    const id = event.toolCallId;
    if (id === undefined) return;
    const spans = this.tools.get(id);
    if (!spans) return;
    this.tools.delete(id);

    const { toolSpan, execSpan, startMs } = spans;
    const success = !event.isError;
    attr(execSpan, "success", success);
    const durationMs = Date.now() - startMs;
    attr(toolSpan, "duration_ms", durationMs);
    attr(execSpan, "duration_ms", durationMs);

    if (event.isError) {
      execSpan.setStatus({ code: SpanStatusCode.ERROR });
      if (this.config.content.toolDetails) {
        attr(execSpan, "error", serialize(event.result));
      }
    }

    if (this.config.content.toolContent) {
      const output = serialize(event.result);
      if (output !== undefined) toolSpan.addEvent("tool.output", { "tool.output": output });
    }

    execSpan.end();
    toolSpan.end();
  }

  /**
   * Close the current pi.interaction span and any llm_request or tool spans still
   * open beneath it, resetting all span state. Safe to call when nothing is open.
   */
  private closeInteraction(): void {
    if (this.llmSpan) {
      this.llmSpan.end();
      this.llmSpan = undefined;
    }
    for (const { toolSpan, execSpan } of this.tools.values()) {
      execSpan.end();
      toolSpan.end();
    }
    this.tools.clear();
    if (this.interactionSpan) {
      attr(this.interactionSpan, "duration_ms", Date.now() - this.interactionStartMs);
      this.interactionSpan.end();
      this.interactionSpan = undefined;
    }
  }
}

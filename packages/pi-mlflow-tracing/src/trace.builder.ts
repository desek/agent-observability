/**
 * @agents-index Reconstructs one MLflow conversation trace from pi's lifecycle
 *   events: a root AGENT span per agent loop carrying the prompt, the final
 *   assistant text, and the session id; a child LLM span per turn carrying the
 *   model and token usage; and a child TOOL span per tool call, parented to the
 *   turn that issued it, carrying the tool name, input, and result. Reserved
 *   MLflow attribute values are JSON-encoded; the session id rides as a plain
 *   OpenTelemetry attribute.
 *
 * Why: MLflow 3.15 derives a trace's request and response previews, its span
 * classifications, its per-turn token usage, and its session grouping from a
 * fixed set of reserved span attributes read off an OpenTelemetry span tree
 * (verified against the pinned server). This module owns the reconstruction state
 * machine so the index factory only forwards events, and so the exact reserved
 * names and their JSON-encoding rule live in one place for Phase 4's exporter to
 * translate into real OpenTelemetry spans. pi's tool events fire before the
 * turn_end that finalizes their turn, so tool spans are buffered and adopted by
 * the turn span when the turn ends, which is what parents a tool call under the
 * turn that made it (FR7). The builder holds conversation content only for the
 * duration of one loop and releases every reference when the loop's trace is
 * taken (NFR3), so a completed export leaves no prompt, response, or tool content
 * behind. It never throws for a malformed event; a missing field degrades to a
 * thinner span rather than a crash (Risk 7). Export and OpenTelemetry emission
 * are Phase 4 and deliberately absent here.
 */

/**
 * MLflow span classification, one of the reserved `mlflow.spanType` values
 * accepted by the pinned server. Only the three this reconstruction uses are
 * named: AGENT for the loop root, LLM for a turn, TOOL for a tool call.
 */
export type MlflowSpanType = "AGENT" | "LLM" | "TOOL";

/**
 * The reserved MLflow span attribute names, verified against the pinned
 * `v3.15.0` server. Every `mlflow.*` value is JSON-encoded (a plain string is a
 * quoted JSON string); `session.id` is a standard OpenTelemetry attribute whose
 * value is the plain session identifier, which is what MLflow reads to group a
 * session's traces together.
 */
export const MLFLOW_ATTR = {
  /** Classifies the span (`AGENT`, `LLM`, `TOOL`). JSON-encoded. */
  spanType: "mlflow.spanType",
  /** Becomes the trace's request preview on the root; a span's input elsewhere. JSON-encoded. */
  spanInputs: "mlflow.spanInputs",
  /** Becomes the trace's response preview on the root; a span's output elsewhere. JSON-encoded. */
  spanOutputs: "mlflow.spanOutputs",
  /** Per-turn token counts under MLflow's usage keys. JSON-encoded. */
  tokenUsage: "mlflow.chat.tokenUsage",
  /** The model identifier for a turn. JSON-encoded. */
  model: "mlflow.llm.model",
  /** The tool (function) name for a tool span. JSON-encoded. */
  functionName: "mlflow.spanFunctionName",
  /** The session identifier on the root span. Plain string, not JSON-encoded. */
  sessionId: "session.id",
} as const;

/**
 * MLflow's token-usage sub-keys, verified against the pinned server's
 * `TokenUsageKey`. Only keys with a value are emitted, so a provider that does
 * not report a cache split simply omits those keys.
 */
interface MlflowTokenUsage {
  input_tokens?: number;
  output_tokens?: number;
  total_tokens?: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
}

/**
 * One reconstructed span in the trace tree. `attributes` holds the exact string
 * values that Phase 4 stamps onto the OpenTelemetry span: reserved `mlflow.*`
 * values are already JSON-encoded, `session.id` is the plain identifier. `type`
 * mirrors the JSON-encoded `mlflow.spanType` attribute in a form convenient for
 * tests and for Phase 4's span construction.
 *
 * @property name - Human-readable span name (the tool name, `turn N`, or `agent`).
 * @property type - The MLflow span classification.
 * @property attributes - The span's attribute map, values pre-encoded for the wire.
 * @property children - Child spans, in the order they were reconstructed.
 */
export interface BuiltSpan {
  name: string;
  type: MlflowSpanType;
  attributes: Record<string, string>;
  children: BuiltSpan[];
}

/**
 * One completed conversation trace: the root AGENT span and the session id it
 * carries. This is the unit the Phase 4 exporter turns into an OpenTelemetry
 * export.
 *
 * @property sessionId - pi's session identity, or undefined when it was not available.
 * @property root - The root AGENT span holding the whole loop's span tree.
 */
export interface BuiltTrace {
  sessionId: string | undefined;
  root: BuiltSpan;
}

/** Loosely-typed view of the `before_agent_start` event fields this builder reads. */
interface PromptEventLike {
  prompt?: unknown;
}

/** Loosely-typed view of a turn's assistant message, read defensively (Risk 7). */
interface TurnMessageLike {
  role?: string;
  model?: string;
  content?: unknown;
  usage?: {
    input?: number;
    output?: number;
    cacheRead?: number;
    cacheWrite?: number;
  };
}

/** Loosely-typed view of the `turn_end` event fields this builder reads. */
interface TurnEndEventLike {
  turnIndex?: number;
  message?: unknown;
}

/** Loosely-typed view of the `tool_execution_start` event fields this builder reads. */
interface ToolStartEventLike {
  toolCallId?: string;
  toolName?: string;
  args?: unknown;
}

/** Loosely-typed view of the `tool_execution_end` event fields this builder reads. */
interface ToolEndEventLike {
  toolCallId?: string;
  toolName?: string;
  result?: unknown;
  isError?: boolean;
}

/**
 * JSON-encode a value for a reserved MLflow attribute. Returns undefined for an
 * absent or non-serializable value so the attribute is omitted rather than set to
 * a broken value.
 *
 * @param value - The value to encode.
 * @returns The JSON string, or undefined when there is nothing serializable.
 */
function encode(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  try {
    return JSON.stringify(value);
  } catch {
    return undefined;
  }
}

/**
 * Set a reserved MLflow attribute to a JSON-encoded value, skipping it entirely
 * when the value is absent or non-serializable.
 *
 * @param attrs - The attribute map to mutate.
 * @param key - The reserved attribute name.
 * @param value - The raw value to JSON-encode.
 */
function putEncoded(attrs: Record<string, string>, key: string, value: unknown): void {
  const encoded = encode(value);
  if (encoded !== undefined) attrs[key] = encoded;
}

/**
 * Set a plain (already-string) attribute, skipping it when absent.
 *
 * @param attrs - The attribute map to mutate.
 * @param key - The attribute name.
 * @param value - The plain string value, or undefined to skip.
 */
function putPlain(attrs: Record<string, string>, key: string, value: string | undefined): void {
  if (value !== undefined) attrs[key] = value;
}

/**
 * Extract plain assistant text from a pi message content field, which may be a
 * string or an array of content parts each optionally carrying `text`. Non-text
 * parts (thinking, tool calls) contribute nothing.
 *
 * @param content - The message content.
 * @returns The concatenated text, or undefined when no text is present.
 */
function extractText(content: unknown): string | undefined {
  if (typeof content === "string") return content.length > 0 ? content : undefined;
  if (Array.isArray(content)) {
    const text = content
      .map((part) => (part && typeof (part as { text?: unknown }).text === "string" ? (part as { text: string }).text : ""))
      .join("");
    return text.length > 0 ? text : undefined;
  }
  return undefined;
}

/**
 * Build MLflow's token-usage object from pi's `Usage` shape, mapping pi's field
 * names to MLflow's reserved keys and computing `total_tokens` from input and
 * output when both are present. Returns undefined when no count is available, so
 * the usage attribute is omitted rather than set to an empty object.
 *
 * @param usage - pi's per-turn usage, or undefined.
 * @returns The MLflow usage object, or undefined when empty.
 */
function toTokenUsage(usage: TurnMessageLike["usage"]): MlflowTokenUsage | undefined {
  if (!usage) return undefined;
  const out: MlflowTokenUsage = {};
  if (typeof usage.input === "number") out.input_tokens = usage.input;
  if (typeof usage.output === "number") out.output_tokens = usage.output;
  if (typeof usage.input === "number" && typeof usage.output === "number") {
    out.total_tokens = usage.input + usage.output;
  }
  if (typeof usage.cacheRead === "number") out.cache_read_input_tokens = usage.cacheRead;
  if (typeof usage.cacheWrite === "number") out.cache_creation_input_tokens = usage.cacheWrite;
  return Object.keys(out).length > 0 ? out : undefined;
}

/**
 * Reconstructs one MLflow conversation trace per pi agent loop from pi's
 * lifecycle events. A single instance is reused across the loops of a session:
 * each loop opens on `beforeAgentStart` and closes on `agentEnd`, which returns
 * the completed trace and releases all retained conversation content (NFR3).
 *
 * Feed events in pi's natural order: `beforeAgentStart`, then interleaved
 * `turnEnd`, `toolExecutionStart`, and `toolExecutionEnd`, then `agentEnd`. Tool
 * spans are buffered as they arrive and adopted by the next turn span, because
 * pi's tool events fire before the `turn_end` that finalizes their turn (FR7).
 *
 * Every method is defensive: a malformed event degrades the trace rather than
 * throwing, and a method called out of sequence is a safe no-op.
 */
export class TraceBuilder {
  /** The root AGENT span of the in-progress loop, or undefined between loops. */
  private root: BuiltSpan | undefined;
  /** The session id captured for the in-progress loop. */
  private sessionId: string | undefined;
  /** The turn spans opened so far in the in-progress loop, in order. */
  private turns: BuiltSpan[] = [];
  /** Tool spans awaiting adoption by the next turn span, in arrival order. */
  private pendingTools: BuiltSpan[] = [];
  /** Pending tool spans indexed by toolCallId, so the end event finds its span. */
  private readonly toolsById = new Map<string, BuiltSpan>();
  /** The latest assistant text seen this loop, used as the root's response preview. */
  private lastAssistantText: string | undefined;

  /**
   * Open a new root AGENT span for one agent loop and capture the user prompt as
   * the trace's request preview. Any unfinished prior loop is discarded first so
   * a missed `agent_end` cannot leak content into the next loop.
   *
   * @param event - The `before_agent_start` event (its `prompt` is read).
   * @param sessionId - pi's session identity, so a session's traces group
   *   together (FR5); undefined when it is not available.
   */
  beforeAgentStart(event: PromptEventLike, sessionId?: string): void {
    this.reset();
    this.sessionId = sessionId;
    const prompt = typeof event?.prompt === "string" ? event.prompt : undefined;
    const attributes: Record<string, string> = {};
    putEncoded(attributes, MLFLOW_ATTR.spanType, "AGENT");
    putEncoded(attributes, MLFLOW_ATTR.spanInputs, prompt);
    putPlain(attributes, MLFLOW_ATTR.sessionId, sessionId);
    this.root = { name: "agent", type: "AGENT", attributes, children: [] };
  }

  /**
   * Open a TOOL span for a tool call and buffer it for adoption by the turn that
   * ends next. The tool input rides in `mlflow.spanInputs`; the result is filled
   * in by `toolExecutionEnd`.
   *
   * @param event - The `tool_execution_start` event.
   */
  toolExecutionStart(event: ToolStartEventLike): void {
    if (!this.root) return;
    const id = typeof event?.toolCallId === "string" ? event.toolCallId : undefined;
    const attributes: Record<string, string> = {};
    putEncoded(attributes, MLFLOW_ATTR.spanType, "TOOL");
    putEncoded(attributes, MLFLOW_ATTR.functionName, event?.toolName);
    putEncoded(attributes, MLFLOW_ATTR.spanInputs, event?.args);
    const span: BuiltSpan = { name: event?.toolName ?? "tool", type: "TOOL", attributes, children: [] };
    this.pendingTools.push(span);
    if (id !== undefined) this.toolsById.set(id, span);
  }

  /**
   * Fill a buffered TOOL span's result into `mlflow.spanOutputs` when the tool
   * finishes. A result with no matching start event is ignored.
   *
   * @param event - The `tool_execution_end` event.
   */
  toolExecutionEnd(event: ToolEndEventLike): void {
    const id = typeof event?.toolCallId === "string" ? event.toolCallId : undefined;
    if (id === undefined) return;
    const span = this.toolsById.get(id);
    if (!span) return;
    putEncoded(span.attributes, MLFLOW_ATTR.spanOutputs, event?.result);
  }

  /**
   * Close one turn: open an LLM span carrying the model and the turn's token
   * usage, adopt every tool span buffered since the last turn as its children
   * (FR7), and record the turn's assistant text as the loop's latest response.
   *
   * @param event - The `turn_end` event (its `message` supplies model, usage, text).
   */
  turnEnd(event: TurnEndEventLike): void {
    if (!this.root) return;
    const message = (event?.message ?? undefined) as TurnMessageLike | undefined;
    const name = typeof event?.turnIndex === "number" ? `turn ${event.turnIndex}` : "turn";
    const attributes: Record<string, string> = {};
    putEncoded(attributes, MLFLOW_ATTR.spanType, "LLM");
    putEncoded(attributes, MLFLOW_ATTR.model, message?.model);
    putEncoded(attributes, MLFLOW_ATTR.tokenUsage, toTokenUsage(message?.usage));

    // Adopt every tool executed since the last turn: pi fires tool events before
    // the turn_end that finalizes their turn, so the current buffer belongs to
    // this turn (FR7).
    const children = this.pendingTools;
    this.pendingTools = [];
    this.toolsById.clear();

    const turnSpan: BuiltSpan = { name, type: "LLM", attributes, children };
    this.turns.push(turnSpan);
    this.root.children.push(turnSpan);

    const text = extractText(message?.content);
    if (text !== undefined) this.lastAssistantText = text;
  }

  /**
   * Close the loop: stamp the final assistant text as the root's response
   * preview, adopt any tool spans still buffered (a loop that ended without a
   * final turn), return the completed trace, and release every reference to
   * conversation content so nothing outlives the export (NFR3, AC-17).
   *
   * @returns The completed trace, or undefined when no loop was open.
   */
  agentEnd(): BuiltTrace | undefined {
    if (!this.root) return undefined;

    // Any tool spans not yet adopted by a turn attach to the last turn if one
    // exists, otherwise directly to the root, so no reconstructed span is lost.
    if (this.pendingTools.length > 0) {
      const parent = this.turns.length > 0 ? this.turns[this.turns.length - 1] : this.root;
      for (const tool of this.pendingTools) parent.children.push(tool);
    }

    putEncoded(this.root.attributes, MLFLOW_ATTR.spanOutputs, this.lastAssistantText);

    const trace: BuiltTrace = { sessionId: this.sessionId, root: this.root };
    this.reset();
    return trace;
  }

  /**
   * Whether the builder currently holds any conversation content. False once a
   * loop's trace has been taken, which is the observable property AC-17 checks.
   *
   * @returns True while a loop is open, false when the builder is idle.
   */
  retainsContent(): boolean {
    return (
      this.root !== undefined ||
      this.turns.length > 0 ||
      this.pendingTools.length > 0 ||
      this.toolsById.size > 0 ||
      this.lastAssistantText !== undefined ||
      this.sessionId !== undefined
    );
  }

  /**
   * Drop every reference to the in-progress loop's content. Called between loops
   * and after a trace is taken so content never outlives its export (NFR3).
   */
  private reset(): void {
    this.root = undefined;
    this.sessionId = undefined;
    this.turns = [];
    this.pendingTools = [];
    this.toolsById.clear();
    this.lastAssistantText = undefined;
  }
}

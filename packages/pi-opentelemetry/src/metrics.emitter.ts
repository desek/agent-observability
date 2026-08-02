/**
 * @agents-index Declares and records the eight pi.* metric instruments
 *   (session/token/cost/lines-of-code/code-edit-decision/commit/pull-request/
 *   active-time) with Claude-Code parity, deriving each value from pi lifecycle
 *   events and attaching cardinality-gated standard attributes.
 *
 * Why: Claude Code exposes eight metric instruments; parity (FR6) means pi must
 * emit the same eight under the pi.* namespace, sourced from pi's lifecycle
 * rather than Claude's. This module owns the Meter and the eight counters so the
 * index factory only has to forward events, and so every record path shares one
 * cardinality-gating implementation. Values pi's events do not carry (for example
 * a rejected code-edit decision, which never reaches tool_result) are simply not
 * emitted; the instrument and its attributes still match Claude Code's shape.
 */

import type { Counter, Meter } from "@opentelemetry/api";
import type { MeterProvider } from "@opentelemetry/sdk-metrics";

import type {
  MessageEndEvent,
  SessionStartEvent,
  ToolResultEvent,
} from "@earendil-works/pi-coding-agent";

import { buildStandardAttributes } from "./attributes.standard.ts";
import type { OtelParityConfig } from "./config.env.ts";
import { INSTRUMENTATION_SCOPE } from "./otel.providers.ts";

/** Maps a file extension (without dot) to a coarse language label for the
 *  code_edit_tool.decision `language` attribute. Unknown extensions are omitted. */
const LANGUAGE_BY_EXT: Record<string, string> = {
  ts: "typescript",
  tsx: "typescript",
  js: "javascript",
  jsx: "javascript",
  py: "python",
  go: "go",
  rs: "rust",
  java: "java",
  rb: "ruby",
  php: "php",
  c: "c",
  h: "c",
  cpp: "cpp",
  cc: "cpp",
  cs: "csharp",
  sh: "shell",
  json: "json",
  yaml: "yaml",
  yml: "yaml",
  md: "markdown",
  html: "html",
  css: "css",
  sql: "sql",
};

/** Successful `git commit` invocation heuristic (commit.count source). */
const COMMIT_RE = /\bgit\b[^\n]*\bcommit\b/;
/** Successful `gh pr create` (or `git ... pull-request`) heuristic (pull_request.count). */
const PR_RE = /\bgh\b[^\n]*\bpr\b[^\n]*\bcreate\b|\bpull-request\b/;

/**
 * Derive a coarse language label from a file path's extension.
 *
 * @param path - File path from an edit/write tool input.
 * @returns A language label, or undefined when the extension is unknown/absent.
 */
function languageFromPath(path: string | undefined): string | undefined {
  if (!path) return undefined;
  const dot = path.lastIndexOf(".");
  if (dot === -1 || dot === path.length - 1) return undefined;
  const ext = path.slice(dot + 1).toLowerCase();
  return LANGUAGE_BY_EXT[ext];
}

/**
 * Count added/removed lines in a unified diff patch. Lines beginning with a
 * single `+`/`-` (but not the `+++`/`---` file headers) count as added/removed.
 *
 * @param patch - Unified patch text, or undefined.
 * @returns Added and removed line counts (both 0 when there is no patch).
 */
function countPatchLines(patch: string | undefined): { added: number; removed: number } {
  let added = 0;
  let removed = 0;
  if (!patch) return { added, removed };
  for (const line of patch.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) added++;
    else if (line.startsWith("-")) removed++;
  }
  return { added, removed };
}

/**
 * Owns the eight pi.* metric instruments and records them from pi lifecycle
 * events with Claude-Code parity. All record methods are best-effort and expect
 * the caller (index factory) to wrap them fail-safe (NFR2).
 */
export class MetricsEmitter {
  private readonly config: OtelParityConfig;
  private readonly sessionCount: Counter;
  private readonly tokenUsage: Counter;
  private readonly costUsage: Counter;
  private readonly linesOfCode: Counter;
  private readonly codeEditDecision: Counter;
  private readonly commitCount: Counter;
  private readonly pullRequestCount: Counter;
  private readonly activeTime: Counter;

  /** Timestamp (ms) of the most recent turn_start awaiting its turn_end. */
  private turnStartTs: number | undefined;

  /**
   * Declare the eight instruments on a Meter obtained from the provider.
   *
   * @param meterProvider - The initialized MeterProvider from otel.providers.
   * @param config - Resolved pi-opentelemetry configuration (cardinality gating).
   */
  constructor(meterProvider: MeterProvider, config: OtelParityConfig) {
    this.config = config;
    const meter: Meter = meterProvider.getMeter(INSTRUMENTATION_SCOPE);

    this.sessionCount = meter.createCounter("pi.session.count", {
      description: "Count of pi CLI sessions started",
    });
    this.tokenUsage = meter.createCounter("pi.token.usage", {
      description: "Number of tokens used",
      unit: "tokens",
    });
    this.costUsage = meter.createCounter("pi.cost.usage", {
      description: "Cost of the pi session in USD",
      unit: "USD",
    });
    this.linesOfCode = meter.createCounter("pi.lines_of_code.count", {
      description: "Count of lines of code modified",
    });
    this.codeEditDecision = meter.createCounter("pi.code_edit_tool.decision", {
      description: "Count of code edit tool permission decisions",
    });
    this.commitCount = meter.createCounter("pi.commit.count", {
      description: "Count of git commits created by pi",
    });
    this.pullRequestCount = meter.createCounter("pi.pull_request.count", {
      description: "Count of pull requests created by pi",
    });
    this.activeTime = meter.createCounter("pi.active_time.total", {
      description: "Total active time in seconds",
      unit: "s",
    });
  }

  /**
   * Record a session start (pi.session.count) with the `start_type` attribute
   * derived from the session_start reason.
   *
   * @param event - The session_start lifecycle event.
   */
  recordSessionStart(event: SessionStartEvent): void {
    this.sessionCount.add(1, {
      ...buildStandardAttributes(this.config),
      start_type: event.reason,
    });
  }

  /**
   * Record token usage (pi.token.usage per type) and cost (pi.cost.usage) from a
   * finalized assistant message's usage. Non-assistant messages are ignored.
   *
   * @param event - The message_end lifecycle event.
   */
  recordMessageEnd(event: MessageEndEvent): void {
    const message = event.message;
    if (!message || (message as { role?: string }).role !== "assistant") return;
    const assistant = message as unknown as {
      model?: string;
      usage?: {
        input: number;
        output: number;
        cacheRead: number;
        cacheWrite: number;
        cost?: { total: number };
      };
    };
    const usage = assistant.usage;
    if (!usage) return;
    const model = assistant.model;
    const base = { ...buildStandardAttributes(this.config), ...(model ? { model } : {}) };

    const byType: Array<[string, number]> = [
      ["input", usage.input],
      ["output", usage.output],
      ["cacheRead", usage.cacheRead],
      ["cacheCreation", usage.cacheWrite],
    ];
    for (const [type, value] of byType) {
      if (value && value > 0) this.tokenUsage.add(value, { ...base, type });
    }

    const cost = usage.cost?.total;
    if (cost && cost > 0) this.costUsage.add(cost, base);
  }

  /**
   * Record tool-derived metrics from a tool_result: lines-of-code and code-edit
   * decisions for edit/write, and commit/pull-request heuristics for bash.
   *
   * @param event - The tool_result lifecycle event.
   */
  recordToolResult(event: ToolResultEvent): void {
    const std = buildStandardAttributes(this.config);
    const toolName = event.toolName;

    if (toolName === "edit" || toolName === "write") {
      const input = (event.input ?? {}) as { path?: string; content?: string };
      const language = languageFromPath(input.path);
      let added = 0;
      let removed = 0;
      if (toolName === "edit") {
        const details = event.details as { patch?: string } | undefined;
        ({ added, removed } = countPatchLines(details?.patch));
      } else {
        // write replaces file content; every content line counts as added.
        added = input.content ? input.content.split("\n").length : 0;
      }
      if (added > 0) this.linesOfCode.add(added, { ...std, type: "added" });
      if (removed > 0) this.linesOfCode.add(removed, { ...std, type: "removed" });

      // A tool_result means the edit executed, i.e. the decision was accept.
      this.codeEditDecision.add(1, {
        ...std,
        decision: "accept",
        tool_name: toolName,
        ...(language ? { language } : {}),
      });
      return;
    }

    if (toolName === "bash" && !event.isError) {
      const command = ((event.input ?? {}) as { command?: string }).command ?? "";
      if (COMMIT_RE.test(command)) this.commitCount.add(1, std);
      if (PR_RE.test(command)) this.pullRequestCount.add(1, std);
    }
  }

  /**
   * Mark the start of a turn for active-time accumulation.
   *
   * @param timestamp - turn_start timestamp in milliseconds.
   */
  turnStart(timestamp: number): void {
    this.turnStartTs = timestamp;
  }

  /**
   * Accumulate active time (pi.active_time.total, seconds) for the elapsed turn.
   *
   * @param timestamp - turn_end timestamp in milliseconds.
   */
  turnEnd(timestamp: number): void {
    if (this.turnStartTs === undefined) return;
    const seconds = (timestamp - this.turnStartTs) / 1000;
    this.turnStartTs = undefined;
    if (seconds > 0) this.activeTime.add(seconds, buildStandardAttributes(this.config));
  }
}

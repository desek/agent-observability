/**
 * @agents-index Unit test for the trace builder: pins that one pi agent loop
 *   reconstructs to one root AGENT span with a turn LLM span per turn and a tool
 *   TOOL span parented to its turn, that the prompt, response, model, and token
 *   usage land in the reserved JSON-encoded MLflow attributes, that a session's
 *   loops share one session id, and that no conversation content outlives the
 *   completed trace.
 *
 * Why: the reconstruction is the heart of this package and its correctness is the
 * MLflow ingest contract's reserved attribute names, their JSON encoding, and the
 * span parentage MLflow reads to render a conversation (AC-3, AC-4, AC-17). These
 * tests drive the builder with synthetic pi events so the span tree and every
 * reserved attribute are pinned without a live tracking server.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { MLFLOW_ATTR, TraceBuilder, type BuiltSpan } from "./trace.builder.ts";

/** Decode a reserved MLflow attribute back to its value for assertions. */
function decode(span: BuiltSpan, key: string): unknown {
  const raw = span.attributes[key];
  return raw === undefined ? undefined : JSON.parse(raw);
}

test("one agent loop makes one trace", () => {
  // A prompt, a tool call inside the first turn, then two turns produce one root
  // with two LLM turn spans and one TOOL span (AC-3).
  const builder = new TraceBuilder();
  builder.beforeAgentStart({ prompt: "list the files" }, "sess-1");
  builder.toolExecutionStart({ toolCallId: "t1", toolName: "ls", args: { path: "." } });
  builder.toolExecutionEnd({ toolCallId: "t1", result: "a.ts\nb.ts", isError: false });
  builder.turnEnd({ turnIndex: 0, message: { role: "assistant", model: "m", content: [{ text: "found two" }] } });
  builder.turnEnd({ turnIndex: 1, message: { role: "assistant", model: "m", content: [{ text: "done" }] } });
  const trace = builder.agentEnd();

  assert.ok(trace, "a loop produces a trace");
  assert.equal(trace.root.type, "AGENT", "the root span is the AGENT span");
  const turns = trace.root.children;
  assert.equal(turns.length, 2, "two turns become two child spans");
  assert.ok(turns.every((t) => t.type === "LLM"), "each turn span is an LLM span");
  const toolSpans = turns.flatMap((t) => t.children);
  assert.equal(toolSpans.length, 1, "the one tool call becomes one tool span");
  assert.equal(toolSpans[0].type, "TOOL", "the tool span is a TOOL span");
});

test("prompt and response land in the reserved attributes", () => {
  // The root's request and response previews are JSON-encoded reserved
  // attributes (AC-3): a plain string is a quoted JSON string.
  const builder = new TraceBuilder();
  builder.beforeAgentStart({ prompt: "what is 2 and 2" }, "sess-1");
  builder.turnEnd({ turnIndex: 0, message: { role: "assistant", model: "m", content: [{ text: "four" }] } });
  const trace = builder.agentEnd();
  assert.ok(trace);

  assert.equal(
    trace.root.attributes[MLFLOW_ATTR.spanInputs],
    JSON.stringify("what is 2 and 2"),
    "the prompt is JSON-encoded into mlflow.spanInputs",
  );
  assert.equal(
    trace.root.attributes[MLFLOW_ATTR.spanOutputs],
    JSON.stringify("four"),
    "the final assistant text is JSON-encoded into mlflow.spanOutputs",
  );
  assert.equal(decode(trace.root, MLFLOW_ATTR.spanType), "AGENT", "the root's span type is AGENT");
});

test("token usage lands on the turn span", () => {
  // The turn's model and token counts map to the reserved LLM attributes (AC-3).
  const builder = new TraceBuilder();
  builder.beforeAgentStart({ prompt: "hello" }, "sess-1");
  builder.turnEnd({
    turnIndex: 0,
    message: {
      role: "assistant",
      model: "claude-x",
      content: [{ text: "hi" }],
      usage: { input: 12, output: 5, cacheRead: 3, cacheWrite: 7 },
    },
  });
  const trace = builder.agentEnd();
  assert.ok(trace);

  const turn = trace.root.children[0];
  assert.equal(decode(turn, MLFLOW_ATTR.model), "claude-x", "the model lands in mlflow.llm.model");
  assert.deepEqual(
    decode(turn, MLFLOW_ATTR.tokenUsage),
    {
      input_tokens: 12,
      output_tokens: 5,
      total_tokens: 17,
      cache_read_input_tokens: 3,
      cache_creation_input_tokens: 7,
    },
    "the token counts map to MLflow's reserved usage keys",
  );
});

test("a tool call parents to its turn", () => {
  // A tool executed before turn one's turn_end nests under turn one, not turn two,
  // proving tool spans parent to the turn that issued them (AC-3).
  const builder = new TraceBuilder();
  builder.beforeAgentStart({ prompt: "run a tool" }, "sess-1");
  builder.toolExecutionStart({ toolCallId: "t1", toolName: "bash", args: { command: "ls" } });
  builder.toolExecutionEnd({ toolCallId: "t1", result: "ok", isError: false });
  builder.turnEnd({ turnIndex: 0, message: { role: "assistant", model: "m", content: [{ text: "ran it" }] } });
  builder.turnEnd({ turnIndex: 1, message: { role: "assistant", model: "m", content: [{ text: "all done" }] } });
  const trace = builder.agentEnd();
  assert.ok(trace);

  const [turnOne, turnTwo] = trace.root.children;
  assert.equal(turnOne.children.length, 1, "the tool span nests under the turn that issued it");
  assert.equal(turnTwo.children.length, 0, "the later turn issued no tool and has no tool span");

  const toolSpan = turnOne.children[0];
  assert.equal(decode(toolSpan, MLFLOW_ATTR.functionName), "bash", "the tool name is recorded");
  assert.deepEqual(decode(toolSpan, MLFLOW_ATTR.spanInputs), { command: "ls" }, "the tool input is recorded");
  assert.equal(decode(toolSpan, MLFLOW_ATTR.spanOutputs), "ok", "the tool result is recorded");
});

test("the root span carries the session id", () => {
  // Two loops in one session: both roots carry the same session.id so MLflow
  // groups the session's traces together (AC-4). session.id is a plain attribute,
  // not JSON-encoded.
  const builder = new TraceBuilder();

  builder.beforeAgentStart({ prompt: "first" }, "sess-42");
  builder.turnEnd({ turnIndex: 0, message: { role: "assistant", model: "m", content: [{ text: "one" }] } });
  const first = builder.agentEnd();

  builder.beforeAgentStart({ prompt: "second" }, "sess-42");
  builder.turnEnd({ turnIndex: 0, message: { role: "assistant", model: "m", content: [{ text: "two" }] } });
  const second = builder.agentEnd();

  assert.ok(first && second);
  assert.equal(first.root.attributes[MLFLOW_ATTR.sessionId], "sess-42", "the first root carries the plain session id");
  assert.equal(second.root.attributes[MLFLOW_ATTR.sessionId], "sess-42", "the second root carries the same session id");
  assert.equal(first.sessionId, second.sessionId, "both traces report the same session identity");
});

test("content is released after export", () => {
  // A completed loop leaves no prompt, response, or tool content behind, so
  // conversation content does not outlive its export (AC-17, NFR3).
  const builder = new TraceBuilder();
  builder.beforeAgentStart({ prompt: "sensitive prompt" }, "sess-1");
  builder.toolExecutionStart({ toolCallId: "t1", toolName: "read", args: { file: "secret" } });
  builder.toolExecutionEnd({ toolCallId: "t1", result: "secret content", isError: false });
  builder.turnEnd({ turnIndex: 0, message: { role: "assistant", model: "m", content: [{ text: "response" }] } });

  assert.equal(builder.retainsContent(), true, "content is held while the loop is open");
  builder.agentEnd();
  assert.equal(builder.retainsContent(), false, "no conversation content is retained after the trace is taken");
});

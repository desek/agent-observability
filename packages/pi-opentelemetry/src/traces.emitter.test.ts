/**
 * @agents-index Unit test for traces.emitter: verifies the span hierarchy nests
 *   pi.llm_request under pi.interaction and pi.tool.execution under pi.tool, driven
 *   by a synthetic lifecycle sequence against a capturing fake Tracer.
 *
 * Why: pi's lifecycle events fire across async boundaries, so the emitter nests
 * spans via explicit parent contexts rather than the ambient call stack (FR8). This
 * test reads back the parent recorded on each span's start context to lock the
 * four-level parity shape without a live Tempo backend.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { trace, type Context, type Span } from "@opentelemetry/api";

import { loadConfig } from "./config.env.ts";
import { TracesEmitter } from "./traces.emitter.ts";

/** A fake span that records its name and lifecycle for assertions. */
interface FakeSpan extends Span {
  __name: string;
  __ended: boolean;
  __parent?: string;
}

test("span-nesting", () => {
  const spans: FakeSpan[] = [];
  const tracer = {
    startSpan(name: string, _opts: unknown, ctx?: Context): FakeSpan {
      const parent = ctx ? (trace.getSpan(ctx) as FakeSpan | undefined) : undefined;
      const span = {
        __name: name,
        __ended: false,
        __parent: parent?.__name,
        setAttribute() { return span; },
        setAttributes() { return span; },
        addEvent() { return span; },
        setStatus() { return span; },
        end() { span.__ended = true; },
        isRecording: () => true,
        recordException() {},
        updateName() { return span; },
        spanContext: () => ({ traceId: "t", spanId: "s", traceFlags: 1 }),
      } as unknown as FakeSpan;
      spans.push(span);
      return span;
    },
  } as never;

  const emitter = new TracesEmitter(tracer, loadConfig({ PI_OTEL_ENABLE: "1" }));

  emitter.beforeAgentStart({ prompt: "hi" });
  emitter.agentStart();
  emitter.llmRequestStart();
  emitter.messageEnd({ message: { role: "assistant", model: "m" } });
  emitter.toolExecutionStart({ toolCallId: "tc1", toolName: "write", args: {} });
  emitter.toolExecutionEnd({ toolCallId: "tc1", isError: false });
  emitter.agentEnd();

  const find = (name: string) => spans.find((s) => s.__name === name);
  const interaction = find("pi.interaction");
  const llm = find("pi.llm_request");
  const tool = find("pi.tool");
  const exec = find("pi.tool.execution");

  assert.ok(interaction, "interaction span created");
  assert.equal(interaction?.__parent, undefined); // root
  assert.equal(llm?.__parent, "pi.interaction");
  assert.equal(tool?.__parent, "pi.interaction");
  assert.equal(exec?.__parent, "pi.tool");

  // Every span is closed by the end of the interaction.
  assert.ok(spans.every((s) => s.__ended), "all spans ended");
});

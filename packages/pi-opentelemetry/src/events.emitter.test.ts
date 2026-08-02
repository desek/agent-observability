/**
 * @agents-index Unit test for events.emitter: verifies content-bearing fields
 *   (prompt, response, tool parameters) are emitted only when their OTEL_LOG_*
 *   flag is on and omitted when off, while non-content fields are always present.
 *
 * Why: content gating is the privacy-parity control (FR9, AC-9); this test drives
 * the emitter against a capturing fake Logger so the "present when on, omitted when
 * off" contract is verified without a live collector.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { loadConfig } from "./config.env.ts";
import { EventsEmitter } from "./events.emitter.ts";

/** A record captured from the fake Logger. */
interface Captured {
  body?: unknown;
  attributes?: Record<string, unknown>;
}

/** Build an EventsEmitter wired to a capturing fake LoggerProvider. */
function makeEmitter(env: Record<string, string>) {
  const records: Captured[] = [];
  const logger = { emit: (r: Captured) => records.push(r) };
  const provider = { getLogger: () => logger } as never;
  return { emitter: new EventsEmitter(provider, loadConfig(env)), records };
}

/** Find the captured record whose body equals name. */
const byBody = (records: Captured[], name: string) =>
  records.find((r) => r.body === name);

test("content-gating", () => {
  // Flags off: prompt/response/tool_parameters omitted; lengths still recorded.
  const off = makeEmitter({ PI_OTEL_ENABLE: "1" });
  off.emitter.userPrompt({ prompt: "secret prompt" });
  off.emitter.messageEnd({
    message: { role: "assistant", model: "m", content: "secret response" },
  });
  off.emitter.toolResult({ toolName: "write", input: { path: "a.ts" }, isError: false });

  const upOff = byBody(off.records, "pi.user_prompt");
  assert.equal(upOff?.attributes?.prompt, undefined);
  assert.equal(upOff?.attributes?.prompt_length, "secret prompt".length);
  const arOff = byBody(off.records, "pi.assistant_response");
  assert.equal(arOff?.attributes?.response, undefined);
  assert.equal(arOff?.attributes?.response_length, "secret response".length);
  const trOff = byBody(off.records, "pi.tool_result");
  assert.equal(trOff?.attributes?.tool_parameters, undefined);
  assert.equal(trOff?.attributes?.tool_name, "write");

  // Flags on: content present.
  const on = makeEmitter({
    PI_OTEL_ENABLE: "1",
    OTEL_LOG_USER_PROMPTS: "1",
    OTEL_LOG_ASSISTANT_RESPONSES: "1",
    OTEL_LOG_TOOL_DETAILS: "1",
  });
  on.emitter.userPrompt({ prompt: "secret prompt" });
  on.emitter.messageEnd({
    message: { role: "assistant", model: "m", content: "secret response" },
  });
  on.emitter.toolResult({ toolName: "write", input: { path: "a.ts" }, isError: false });

  assert.equal(byBody(on.records, "pi.user_prompt")?.attributes?.prompt, "secret prompt");
  assert.equal(
    byBody(on.records, "pi.assistant_response")?.attributes?.response,
    "secret response",
  );
  assert.equal(
    byBody(on.records, "pi.tool_result")?.attributes?.tool_parameters,
    JSON.stringify({ path: "a.ts" }),
  );
});

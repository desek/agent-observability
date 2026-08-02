/**
 * @agents-index Unit test for the experiment resolver: pins that a name resolves
 *   to its numeric id through the tracking API, that an unknown name resolves to a
 *   `not-found` outcome (so the caller refuses to export and states the name and a
 *   fix) rather than guessing an id, and that an unreachable server resolves to a
 *   distinct `unreachable` outcome with exactly one attempt.
 *
 * Why: MLflow groups an ingested trace by numeric id, but the user configures a
 * name, so the name must resolve to an id before any export and the export must be
 * refused, never guessed, when the name does not exist (FR8, FR9, AC-5). The three
 * outcomes are kept distinct because they drive different behaviour (export, state
 * loudly, stay silent), so each is pinned here against a fake fetch with no live
 * server.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { resolveExperimentId, unknownNameMessage, type FetchLike } from "./mlflow.experiment.ts";

test("resolves the experiment by name", async () => {
  // A 200 carrying the experiment object resolves the name to its id (FR9).
  let requestedUrl = "";
  const fetchImpl: FetchLike = async (url) => {
    requestedUrl = url;
    return { ok: true, status: 200, json: async () => ({ experiment: { experiment_id: "2" } }) };
  };
  const result = await resolveExperimentId("http://localhost:1/mlflow", "pi", fetchImpl);
  assert.deepEqual(result, { ok: true, id: "2" }, "the name resolves to its id");
  assert.match(requestedUrl, /experiments\/get-by-name\?experiment_name=pi$/, "it queries get-by-name");
});

test("refuses to export on an unknown name", async () => {
  // A 404 means the name does not exist: the outcome is not-found, so no id is
  // guessed and the caller refuses to export (FR9, AC-5).
  let attempts = 0;
  const fetchImpl: FetchLike = async () => {
    attempts += 1;
    return { ok: false, status: 404, json: async () => ({}) };
  };
  const result = await resolveExperimentId("http://localhost:1/mlflow", "ghost", fetchImpl);
  assert.deepEqual(result, { ok: false, reason: "not-found" }, "an unknown name is not-found, not guessed");
  assert.equal(attempts, 1, "one request, no retry");

  // The actionable message names the failed name and how to create it (FR19, AC-5).
  const message = unknownNameMessage("ghost");
  assert.match(message, /ghost/, "the message names the experiment that failed to resolve");
  assert.match(message, /create/i, "the message states how to create it");
});

test("silent-eligible when the server is unreachable", async () => {
  // A refused connection is unreachable, distinct from not-found, so the caller can
  // stay silent rather than print a user error (FR16, AC-11). Exactly one attempt.
  let attempts = 0;
  const fetchImpl: FetchLike = async () => {
    attempts += 1;
    throw new Error("ECONNREFUSED");
  };
  const result = await resolveExperimentId("http://localhost:1/mlflow", "pi", fetchImpl);
  assert.deepEqual(result, { ok: false, reason: "unreachable" }, "an unreachable server is not not-found");
  assert.equal(attempts, 1, "one request, no retry storm");
});

/**
 * @agents-index Resolves an MLflow experiment name to its numeric id against the
 *   tracking server's REST API (experiments/get-by-name), returning a
 *   discriminated result that separates a resolved id, an unknown name, and an
 *   unreachable server, so the caller can refuse to export on an unknown name
 *   (loud, actionable) yet stay silent when the server is simply absent.
 *
 * Why: MLflow's OpenTelemetry ingest endpoint groups a trace into an experiment by
 * the numeric id sent in the x-mlflow-experiment-id header, but the user
 * configures a name (FR8, FR9). Guessing an id would write conversation content
 * into the wrong experiment or a non-existent one, so the name is resolved to an
 * id first and the export is refused rather than guessed when the name resolves to
 * nothing (FR9, AC-5). The three outcomes are kept distinct because they demand
 * different behaviour: a resolved id exports; an unknown name is a user error that
 * must be stated with a fix (FR19, AC-5); an unreachable server is the
 * stack-is-down case that must stay silent with no error and no retry storm (FR16,
 * NFR6, AC-11).
 */

/**
 * The outcome of resolving an experiment name.
 *
 * @property ok - True only when the name resolved to an id.
 * @property id - The numeric experiment id, present only when `ok` is true.
 * @property reason - Why resolution failed: `not-found` when the server answered
 *   that the name does not exist (a user error to state), `unreachable` when the
 *   server could not be reached or gave an unusable answer (the stack-is-down case
 *   to stay silent about).
 */
export type ExperimentResolution =
  | { ok: true; id: string }
  | { ok: false; reason: "not-found" }
  | { ok: false; reason: "unreachable" };

/** The subset of the Fetch API this resolver needs, injectable for tests. */
export type FetchLike = (
  input: string,
  init?: { method?: string; signal?: AbortSignal },
) => Promise<{
  ok: boolean;
  status: number;
  json: () => Promise<unknown>;
}>;

/**
 * The shape of MLflow's `experiments/get-by-name` success body: the experiment
 * object carries the numeric id under `experiment_id`.
 */
interface GetByNameBody {
  experiment?: { experiment_id?: unknown };
}

/**
 * Build the actionable message for an experiment name that does not resolve.
 * Names the name that failed, why no export was sent, and how to create the
 * experiment, so the reader can act rather than only diagnose (FR9, FR19, AC-5,
 * AC-19).
 *
 * @param name - The experiment name that failed to resolve.
 * @returns The message to surface to the user.
 */
export function unknownNameMessage(name: string): string {
  return (
    `pi-mlflow-tracing: mlflow.experiment.ts: the experiment "${name}" does not ` +
    `exist on the tracking server, so no conversation was exported (an id is ` +
    `never guessed). ` +
    `To fix, create it (the stack provisions "pi" at start; otherwise create it ` +
    `in the MLflow UI or with the tracking API), or set PI_MLFLOW_EXPERIMENT to ` +
    `the name of an experiment that exists. ` +
    `After changing it, re-run a pi turn and confirm a trace appears under that ` +
    `experiment.`
  );
}

/**
 * Resolve an experiment name to its numeric id through MLflow's REST API.
 *
 * Issues one GET to `{trackingUri}/api/2.0/mlflow/experiments/get-by-name`. A 200
 * with an `experiment_id` resolves; a 404 (or any answer that names the experiment
 * as missing) is `not-found`; a network error, a timeout, or an unusable body is
 * `unreachable`. Exactly one request is made, so an absent server produces no
 * retry storm (FR16, NFR6, AC-11).
 *
 * @param trackingUri - The MLflow tracking address (REST base, no trailing slash).
 * @param name - The experiment name to resolve.
 * @param fetchImpl - Fetch implementation; defaults to the global `fetch`.
 * @param timeoutMs - Abort the request after this many milliseconds so a hung
 *   server cannot stall session start.
 * @returns The resolution outcome.
 */
export async function resolveExperimentId(
  trackingUri: string,
  name: string,
  fetchImpl: FetchLike = fetch as unknown as FetchLike,
  timeoutMs = 3000,
): Promise<ExperimentResolution> {
  const url =
    `${trackingUri.replace(/\/+$/, "")}/api/2.0/mlflow/experiments/get-by-name` +
    `?experiment_name=${encodeURIComponent(name)}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { method: "GET", signal: controller.signal });
    // 404 is MLflow's answer for a name that does not exist: a user error to
    // state, not a server-down case to stay silent about (AC-5).
    if (res.status === 404) return { ok: false, reason: "not-found" };
    if (!res.ok) return { ok: false, reason: "unreachable" };
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      return { ok: false, reason: "unreachable" };
    }
    const id = (body as GetByNameBody)?.experiment?.experiment_id;
    if (typeof id === "string" && id !== "") return { ok: true, id };
    if (typeof id === "number") return { ok: true, id: String(id) };
    // A 200 without a usable id means the name is not present.
    return { ok: false, reason: "not-found" };
  } catch {
    // A refused connection, a DNS failure, or an abort: the server is not
    // reachable, so stay silent with no retry (FR16, NFR6, AC-11).
    return { ok: false, reason: "unreachable" };
  } finally {
    clearTimeout(timer);
  }
}

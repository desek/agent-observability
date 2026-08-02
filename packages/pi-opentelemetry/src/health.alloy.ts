/**
 * @agents-index Probes the local Alloy collector's health endpoint so the
 *   extension can decide, when otherwise unconfigured, whether to enable
 *   telemetry (dynamic default enabled).
 *
 * Why: the extension defaults to enabled with a localhost OTLP endpoint, but on
 * a machine where the observability stack is not running that would emit into a
 * dead endpoint. Probing Alloy's default health route lets pi silently stay off
 * when the collector is absent and turn itself on when it is present, with no env
 * configuration. The probe is fail-safe and time-bounded so it can never hang or
 * crash pi startup: any error, non-200, or timeout resolves to "not healthy".
 */

/**
 * Grafana Alloy's native default health route: its HTTP server listens on
 * `localhost:12345` and serves `/-/healthy`. This is the upstream Alloy default,
 * a promise a stranger can verify against Alloy's own documentation, so an
 * unconfigured machine that happens to run a default Alloy is detected and an
 * unconfigured machine that runs nothing stays silent. A collector fronted
 * behind a different address, such as this project's single-port edge proxy, is
 * reached by setting the probe URL or by enabling export explicitly, rather than
 * by inheriting a project-specific port and path as a package default.
 */
export const DEFAULT_ALLOY_HEALTH_URL = "http://localhost:12345/-/healthy";

/** Default probe timeout: short so it never noticeably delays pi startup. */
export const DEFAULT_PROBE_TIMEOUT_MS = 500;

/**
 * Return whether the local Alloy collector reports healthy.
 *
 * Issues a single GET against the health URL with an abort-based timeout.
 * Resolves true only on a 2xx response; any network error, non-2xx status, or
 * timeout resolves false so the caller treats the collector as absent.
 *
 * @param url - Health endpoint to probe; defaults to Grafana Alloy's native
 *   health route at localhost:12345/-/healthy.
 * @param timeoutMs - Abort timeout in milliseconds.
 * @returns True when the endpoint responds 2xx within the timeout, else false.
 */
export async function probeAlloyHealthy(
  url: string = DEFAULT_ALLOY_HEALTH_URL,
  timeoutMs: number = DEFAULT_PROBE_TIMEOUT_MS,
): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

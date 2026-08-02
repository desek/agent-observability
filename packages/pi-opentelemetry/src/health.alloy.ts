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
 * Alloy's default health route, served through the single HAProxy edge-proxy
 * loopback port. Alloy is no longer published on :12345; the proxy maps
 * the `/alloy/` prefix to Alloy's UI/health, so `/alloy/-/healthy` reaches Alloy's
 * `/-/healthy` over the internal network.
 */
export const DEFAULT_ALLOY_HEALTH_URL = "http://localhost:24317/alloy/-/healthy";

/** Default probe timeout: short so it never noticeably delays pi startup. */
export const DEFAULT_PROBE_TIMEOUT_MS = 500;

/**
 * Return whether the local Alloy collector reports healthy.
 *
 * Issues a single GET against the health URL with an abort-based timeout.
 * Resolves true only on a 2xx response; any network error, non-2xx status, or
 * timeout resolves false so the caller treats the collector as absent.
 *
 * @param url - Health endpoint to probe; defaults to Alloy via the HAProxy
 *   edge-proxy port at localhost:24317/alloy/-/healthy.
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

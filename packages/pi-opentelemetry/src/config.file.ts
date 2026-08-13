/**
 * @agents-index Reads an optional observability.json config file at pi's global
 *   scope (~/.pi/agent/observability.json) and project scope
 *   (<cwd>/.pi/observability.json), merges them project-over-global into a flat
 *   map of environment-variable names, and layers the process environment on top
 *   so an explicit environment variable always wins over the file. Every read is
 *   fail-safe: a missing or malformed file yields an empty map, never an error.
 *
 * Why: the extension's whole configuration surface is the OTEL_* and
 * PI_AGENT_ENABLE_TELEMETRY environment variables (see config.env.ts), but a process
 * environment is awkward to set per project and is not committable. A JSON file
 * at pi's own config scopes gives a project-local, committable configuration path
 * that matches the pattern of pi's bundled preset extension, while keeping the
 * environment as the authoritative override. The file holds the same variable
 * names as the environment, so there is one vocabulary and one parser
 * (config.env.ts) rather than a second schema to keep in sync. Reads are injected
 * so this module stays pure and unit-testable, and defensive so a broken config
 * file can never crash or block pi (NFR2).
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Note: @earendil-works/pi-coding-agent is a peer dependency and is imported
// lazily inside resolvePiPaths() rather than at module top level. A top-level
// value import would require the peer to be present the instant this module
// loads, which breaks loading the extension in isolation (for example the
// package install smoke test, which loads the manifest entry without the peer
// installed). Only type-only imports from the peer are erased at runtime and
// safe at top level.

/** Environment map shape (a subset of `process.env`). */
type Env = Record<string, string | undefined>;

/** Default project config directory name when pi's CONFIG_DIR_NAME is unavailable. */
const DEFAULT_CONFIG_DIR_NAME = ".pi";

/**
 * Resolve pi's agent config directory and project config directory name.
 *
 * Prefers pi's own `getAgentDir()` and `CONFIG_DIR_NAME` (which honor a
 * rebranded distribution and the agent-dir environment override) by importing
 * the peer lazily. When the peer is not present, for example when the extension
 * entry is loaded in isolation, it falls back to replicating pi's default
 * resolution: the `*_CODING_AGENT_DIR` override, else `~/.pi/agent`, and the
 * default `.pi` config directory name. This never throws.
 *
 * @param processEnv - The process environment (for the agent-dir override).
 * @returns The agent directory and the project config directory name.
 */
async function resolvePiPaths(
  processEnv: Env = process.env,
): Promise<{ agentDir: string; configDirName: string }> {
  try {
    const pi = await import("@earendil-works/pi-coding-agent");
    return { agentDir: pi.getAgentDir(), configDirName: pi.CONFIG_DIR_NAME };
  } catch {
    // Peer absent: replicate pi's default agent-dir resolution without it.
    const override = processEnv.PI_CODING_AGENT_DIR;
    const agentDir =
      override && override.trim() !== ""
        ? override.replace(/^~(?=$|\/|\\)/, homedir())
        : join(homedir(), DEFAULT_CONFIG_DIR_NAME, "agent");
    return { agentDir, configDirName: DEFAULT_CONFIG_DIR_NAME };
  }
}

/**
 * Name of the optional config file, read at both the global and project scope.
 * The file is a flat JSON object whose keys are the same environment-variable
 * names the extension already understands (PI_AGENT_ENABLE_TELEMETRY, OTEL_*), so the file
 * and the environment share one vocabulary.
 */
export const CONFIG_FILE_NAME = "observability.json";

/**
 * Injected filesystem and path dependencies, so the loader stays pure and
 * unit-testable. Production wiring passes the real `node:fs` reads plus pi's
 * `getAgentDir()` and the launch directory.
 *
 * @property agentDir - pi's agent config directory (global scope root).
 * @property cwd - the launch directory (project scope root).
 * @property configDirName - the project config directory name (defaults to `.pi`).
 * @property exists - existence check for a path (defaults to `existsSync`).
 * @property read - UTF-8 file reader for a path (defaults to `readFileSync`).
 */
export interface FileEnvDeps {
  agentDir: string;
  cwd: string;
  configDirName?: string;
  exists?: (path: string) => boolean;
  read?: (path: string) => string;
}

/**
 * Read and parse one config file into a flat string map, or return an empty map
 * when the file is absent, unreadable, not an object, or not valid JSON. Every
 * value is coerced to a string so the result can be layered into an environment
 * map; nested objects and arrays are dropped because an environment value is a
 * string. This function never throws (NFR2).
 *
 * @param path - Absolute path to the candidate config file.
 * @param exists - Existence check.
 * @param read - UTF-8 reader.
 * @returns A flat map of variable name to string value; empty on any problem.
 */
function readOne(
  path: string,
  exists: (path: string) => boolean,
  read: (path: string) => string,
): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    if (!exists(path)) return out;
    const parsed: unknown = JSON.parse(read(path));
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      // A config file must be a JSON object of name/value pairs. Anything else is
      // ignored rather than trusted, so a malformed file degrades to no config.
      console.error(
        `pi-opentelemetry: ${CONFIG_FILE_NAME} at ${path} is not a JSON object; ignoring it.`,
      );
      return out;
    }
    for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
      if (value === null || value === undefined) continue;
      if (typeof value === "object") continue; // environment values are scalars
      out[key] = String(value);
    }
  } catch (err) {
    // Malformed JSON or a read error must never break pi; degrade to no config.
    console.error(`pi-opentelemetry: failed to read ${CONFIG_FILE_NAME} at ${path}: ${err}`);
  }
  return out;
}

/**
 * Load the observability.json config as a flat environment-variable map, reading
 * the global scope first and the project scope second so a project file overrides
 * a global file for the same key. The result is intended to be layered under the
 * process environment by {@link mergeEnv}.
 *
 * @param deps - Injected directories and filesystem reads.
 * @returns Merged flat map (project over global); empty when neither file exists.
 */
export function loadFileEnv(deps: FileEnvDeps): Record<string, string> {
  const exists = deps.exists ?? existsSync;
  const read = deps.read ?? ((p: string) => readFileSync(p, "utf-8"));

  const configDirName = deps.configDirName ?? DEFAULT_CONFIG_DIR_NAME;
  const globalPath = join(deps.agentDir, CONFIG_FILE_NAME);
  const projectPath = join(deps.cwd, configDirName, CONFIG_FILE_NAME);

  const globalEnv = readOne(globalPath, exists, read);
  const projectEnv = readOne(projectPath, exists, read);

  // Project overrides global for any shared key.
  return { ...globalEnv, ...projectEnv };
}

/**
 * Layer the process environment over the file-derived map so an explicit
 * environment variable always wins over the file. A key present in the process
 * environment overrides the same key from the file; a key only in the file
 * passes through as a default.
 *
 * @param fileEnv - Flat map from {@link loadFileEnv}.
 * @param processEnv - The process environment (defaults to `process.env`).
 * @returns The effective environment to hand to `loadConfig`.
 */
export function mergeEnv(fileEnv: Record<string, string>, processEnv: Env = process.env): Env {
  return { ...fileEnv, ...processEnv };
}

/**
 * Convenience composition used by the extension entry point: read the config
 * file at both scopes, then layer the process environment on top. Fail-safe: any
 * unexpected error resolves to the process environment unchanged, so telemetry
 * configuration never depends on a readable file.
 *
 * @param cwd - The launch directory (defaults to `process.cwd()`).
 * @param processEnv - The process environment (defaults to `process.env`).
 * @returns A promise for the effective environment, environment variables winning.
 */
export async function loadEffectiveEnv(
  cwd: string = process.cwd(),
  processEnv: Env = process.env,
): Promise<Env> {
  try {
    const { agentDir, configDirName } = await resolvePiPaths(processEnv);
    const fileEnv = loadFileEnv({ agentDir, cwd, configDirName });
    return mergeEnv(fileEnv, processEnv);
  } catch {
    return processEnv;
  }
}

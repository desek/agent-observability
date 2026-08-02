/**
 * @agents-index Derives git provenance (git.org, git.repo, git.branch, git.path)
 *   from the pi launch directory by shelling out to git, so telemetry carries
 *   per-repo provenance with zero environment configuration.
 *
 * Why: provenance was previously a passthrough of OTEL_RESOURCE_ATTRIBUTES, which
 * forced every repo to be wired with a direnv/env hook before pi telemetry could
 * be sliced per repo and branch. The pi extension already runs in-process at the
 * session's working directory, so it can compute the same attributes itself. git
 * resolves the enclosing repository even when pi is launched from a subdirectory,
 * making this more robust than an .envrc that only sees its own directory. The
 * derivation is fully fail-safe: outside a git repo, or without git installed, it
 * returns an empty map and the caller simply attaches no provenance.
 *
 * Precedence is the caller's concern: explicit OTEL_RESOURCE_ATTRIBUTES should
 * win over these derived values (env wins), so a repo that is wired keeps its
 * exact configured provenance while un-wired repos get this zero-config fallback.
 */

import { execFileSync } from "node:child_process";
import { basename } from "node:path";

/** Attribute keys emitted, matching the OTEL_RESOURCE_ATTRIBUTES convention. */
const ATTR_ORG = "git.org";
const ATTR_REPO = "git.repo";
const ATTR_BRANCH = "git.branch";
const ATTR_PATH = "git.path";

/**
 * Run a git subcommand in a directory, returning trimmed stdout or undefined.
 *
 * Fail-safe by design: a non-zero exit (not a repo, detached state, missing
 * remote) or a missing git binary yields undefined rather than throwing, so
 * provenance derivation degrades gracefully.
 *
 * @param cwd - Directory to run git in.
 * @param args - git arguments (e.g. ["rev-parse", "--show-toplevel"]).
 * @returns Trimmed stdout, or undefined when the command fails or is empty.
 */
function git(cwd: string, args: string[]): string | undefined {
  try {
    const out = execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return out === "" ? undefined : out;
  } catch {
    return undefined;
  }
}

/**
 * Split an origin remote URL into org and repo segments.
 *
 * Handles both SSH (`git@host:org/repo.git`) and HTTPS
 * (`https://host/org/repo(.git)`) forms by matching the final two path
 * segments. When no remote is available, falls back to the repository's
 * top-level directory name as the repo, with no org.
 *
 * @param url - origin remote URL, or undefined when unset.
 * @param toplevel - Absolute path to the repository root (basename fallback).
 * @returns The parsed org (optional) and repo (best-effort).
 */
function parseRemote(
  url: string | undefined,
  toplevel: string,
): { org?: string; repo?: string } {
  if (!url) return { repo: basename(toplevel) };
  const cleaned = url.replace(/\.git$/, "");
  const match = cleaned.match(/[:/]([^/]+)\/([^/]+)$/);
  if (match) return { org: match[1], repo: match[2] };
  return { repo: basename(cleaned) };
}

/**
 * Derive git provenance attributes for the given working directory.
 *
 * Returns git.path (the working directory), plus git.org, git.repo, and
 * git.branch when resolvable. Outside a git repository the map is empty, so the
 * caller attaches no provenance at all.
 *
 * @param cwd - Working directory to inspect; defaults to the pi process cwd.
 * @returns A resource-attribute map (possibly empty); never throws.
 */
export function deriveGitProvenance(cwd: string = process.cwd()): Record<string, string> {
  const toplevel = git(cwd, ["rev-parse", "--show-toplevel"]);
  if (!toplevel) return {};

  const { org, repo } = parseRemote(git(cwd, ["remote", "get-url", "origin"]), toplevel);
  const branch = git(cwd, ["branch", "--show-current"]);

  const attrs: Record<string, string> = { [ATTR_PATH]: cwd };
  if (org) attrs[ATTR_ORG] = org;
  if (repo) attrs[ATTR_REPO] = repo;
  if (branch) attrs[ATTR_BRANCH] = branch;
  return attrs;
}

/**
 * @agents-index Unit tests for provenance.git: verifies git.org/repo/branch/path
 *   derivation from a real temporary repo (SSH and HTTPS remotes) and the empty
 *   result outside a repository.
 *
 * Why: self-derived provenance is the zero-config fallback that replaces the
 * OTEL_RESOURCE_ATTRIBUTES env dependency; these tests lock the remote-parsing
 * and fail-safe behaviour so a parsing regression cannot silently mislabel or
 * crash telemetry.
 */

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

/** Initialize a throwaway git repo with a fixed branch and optional origin. */
function makeRepo(remote?: string): string {
  const dir = mkdtempSync(join(tmpdir(), "prov-git-"));
  const run = (...args: string[]) =>
    execFileSync("git", args, { cwd: dir, stdio: ["ignore", "ignore", "ignore"] });
  run("-c", "init.defaultBranch=main", "init");
  if (remote) run("remote", "add", "origin", remote);
  return dir;
}

test("derives-org-repo-branch-path-from-ssh-remote", async () => {
  const { deriveGitProvenance } = await import("./provenance.git.ts");
  const dir = makeRepo("git@github.com:acme/widget.git");
  try {
    const attrs = deriveGitProvenance(dir);
    assert.equal(attrs["git.org"], "acme");
    assert.equal(attrs["git.repo"], "widget");
    assert.equal(attrs["git.branch"], "main");
    assert.equal(attrs["git.path"], dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("parses-https-remote-and-strips-dot-git", async () => {
  const { deriveGitProvenance } = await import("./provenance.git.ts");
  const dir = makeRepo("https://gitlab.com/team/proj.git");
  try {
    const attrs = deriveGitProvenance(dir);
    assert.equal(attrs["git.org"], "team");
    assert.equal(attrs["git.repo"], "proj");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("falls-back-to-toplevel-basename-without-remote", async () => {
  const { deriveGitProvenance } = await import("./provenance.git.ts");
  const dir = makeRepo();
  try {
    const attrs = deriveGitProvenance(dir);
    assert.equal(attrs["git.org"], undefined);
    // repo is the temp dir's basename; org absent with no remote.
    assert.ok(attrs["git.repo"] && attrs["git.repo"].length > 0);
    assert.equal(attrs["git.path"], dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("returns-empty-outside-a-git-repo", async () => {
  const { deriveGitProvenance } = await import("./provenance.git.ts");
  const dir = mkdtempSync(join(tmpdir(), "prov-nogit-"));
  try {
    assert.deepEqual(deriveGitProvenance(dir), {});
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

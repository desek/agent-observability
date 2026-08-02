/**
 * @agents-index Publishability tests for package.json: asserts the scoped name,
 *   Apache-2.0 license, repository/homepage/bugs pointing at this repository, the
 *   pi-package keyword, an explicit files list, public publishConfig, an engines
 *   range, that the pi entry point resolves to a file the files list would ship
 *   (the silent-no-op guard), that the OpenTelemetry API package is a peer and
 *   not an ordinary dependency, and that the manifest version matches the newest
 *   changelog heading.
 *
 * Why: publication turns the manifest into a public contract, and a manifest
 * that omits src/ from the files list produces a package that installs cleanly
 * and does nothing, with no error (Phase 2 finding). These assertions fail the
 * build before such a package can be published, so the contract is machine-
 * checked rather than eyeballed.
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

/** Directory of this test file: `<package>/src`. */
const here = dirname(fileURLToPath(import.meta.url));
/** Package root: the directory that holds package.json. */
const packageRoot = resolve(here, "..");

/** Parsed package manifest under test. */
const manifest = JSON.parse(
  readFileSync(join(packageRoot, "package.json"), "utf8"),
) as Record<string, unknown>;

/**
 * Compile a single npm `files` glob (negation prefix already stripped) into an
 * anchored RegExp over posix-style relative paths. Handles the three glob forms
 * the files list uses: a `/**\/` segment that matches zero or more directories,
 * a `**` that matches across directory boundaries, and a `*` that matches within
 * one path segment.
 *
 * @param glob - A single files pattern without any leading `!`.
 * @returns A RegExp anchored to the whole relative path.
 */
function globToRegExp(glob: string): RegExp {
  const escaped = glob
    .replace(/\\/g, "/")
    .replace(/[.+^${}()|[\]]/g, "\\$&")
    .replace(/\/\*\*\//g, "/(?:.+/)?")
    .replace(/\*\*/g, ".*")
    .replace(/\*/g, "[^/]*");
  return new RegExp(`^${escaped}$`);
}

/**
 * Decide whether a relative path would be shipped by an npm `files` list,
 * applying the patterns in order so a later negation removes an earlier match,
 * exactly as npm resolves the list.
 *
 * @param relPath - Posix-style path relative to the package root.
 * @param files - The manifest `files` array.
 * @returns True when the last matching pattern is an include.
 */
function shippedByFiles(relPath: string, files: string[]): boolean {
  let included = false;
  for (const pattern of files) {
    const negated = pattern.startsWith("!");
    const raw = negated ? pattern.slice(1) : pattern;
    if (globToRegExp(raw).test(relPath)) included = !negated;
  }
  return included;
}

test("manifest declares publishable fields", () => {
  assert.equal(manifest.name, "@desek/pi-opentelemetry");
  assert.equal(manifest.private, undefined, "private must be absent to publish");
  assert.equal(manifest.version, "0.1.0");
  assert.equal(manifest.license, "Apache-2.0");
  assert.ok(existsSync(join(packageRoot, "LICENSE")), "a LICENSE file must ship");

  const repository = manifest.repository as { url?: string; directory?: string };
  assert.match(repository.url ?? "", /desek\/agent-observability/);
  assert.equal(repository.directory, "packages/pi-opentelemetry");
  assert.match(String(manifest.homepage ?? ""), /desek\/agent-observability/);
  const bugs = manifest.bugs as { url?: string };
  assert.match(bugs.url ?? "", /desek\/agent-observability/);

  const keywords = manifest.keywords as string[];
  assert.ok(
    keywords.includes("pi-package"),
    "keywords must contain pi-package for the pi gallery",
  );

  const publishConfig = manifest.publishConfig as { access?: string };
  assert.equal(
    publishConfig.access,
    "public",
    "a scoped package defaults to restricted, so public access must be explicit",
  );

  const engines = manifest.engines as { node?: string };
  assert.ok(engines.node, "engines.node must name the supported Node versions");

  assert.ok(Array.isArray(manifest.files), "files must be an explicit list");
});

test("manifest entry point exists on disk and the files list would ship it", () => {
  const pi = manifest.pi as { extensions?: string[] };
  const files = manifest.files as string[];
  assert.ok(pi.extensions && pi.extensions.length > 0, "pi.extensions must be declared");

  for (const entry of pi.extensions) {
    const relPath = entry.replace(/^\.\//, "");
    assert.ok(
      existsSync(join(packageRoot, relPath)),
      `entry point ${entry} must exist on disk`,
    );
    assert.ok(
      shippedByFiles(relPath, files),
      `entry point ${relPath} must be included by the files list, else the package is a silent no-op`,
    );
  }

  // The guard's mirror image: a sibling test file must NOT ship (NFR4).
  assert.equal(
    shippedByFiles("src/package.manifest.test.ts", files),
    false,
    "test files must be excluded from the published tarball",
  );
});

test("api package is a peer dependency", () => {
  const peers = (manifest.peerDependencies ?? {}) as Record<string, string>;
  const deps = (manifest.dependencies ?? {}) as Record<string, string>;
  assert.ok(
    peers["@opentelemetry/api"],
    "@opentelemetry/api must be a peer dependency",
  );
  assert.equal(
    deps["@opentelemetry/api"],
    undefined,
    "@opentelemetry/api must not also be an ordinary dependency; two copies break registration",
  );
});

test("version agrees with changelog", () => {
  const changelog = readFileSync(join(packageRoot, "CHANGELOG.md"), "utf8");
  const match = changelog.match(/^##\s+(\d+\.\d+\.\d+)/m);
  assert.ok(match, "CHANGELOG.md must have a versioned heading");
  assert.equal(
    match[1],
    manifest.version,
    "the newest changelog heading must equal the manifest version",
  );
});

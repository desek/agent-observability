#!/usr/bin/env bash
#
# pi-package.verify.sh
#
# @agents-index Install smoke test for @desek/pi-opentelemetry: packs the package, installs the tarball into a clean temporary project, loads the pi manifest entry through jiti exactly as pi does, and asserts the tarball ships no test file and no lockfile.
#
# Purpose: prove that a registry-installed tarball is not a silent no-op. The
# package's worst failure is installing cleanly while shipping an incomplete
# import graph, so pi finds the manifest entry, loads nothing, and stays quiet.
# This script closes that gap the way a user hits it, asserting four facts, each
# reported as its own check:
#   1. The packed tarball contains no test file (they would leak internals and
#      bloat the install).
#   2. The packed tarball contains no lockfile (a published lockfile pins a
#      consumer's tree).
#   3. The tarball installs into a clean project and the pi manifest entry
#      resolves to a file on disk.
#   4. That entry loads through jiti (pi's own transpiling loader) and returns
#      an extension factory function.
# The script exits non-zero on the first failure. Every failure names what
# failed, the fix, and what to check after the fix. It needs no running stack
# and no network beyond the npm registry the install reads from.
#
# Usage:
#   scripts/pi-package.verify.sh      Pack, install into a clean dir, and load.
#   scripts/pi-package.verify.sh -h   Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0. The script takes no other argument.
#
# Environment:
#   JITI_VERSION  jiti version installed into the clean project to load the
#                 TypeScript entry. Defaults to the version pi pins (2.7.0).

set -euo pipefail

# Print each line of a newline-separated list indented by four spaces, to stderr.
# Used to show the offending tarball entries under a failure heading.
indent_lines() {
	local line
	while IFS= read -r line; do
		echo "    $line" >&2
	done <<<"$1"
}

# --- Location ----------------------------------------------------------------
# Resolve the repository root and the package directory from the script
# location so the checks run the same way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
pkg_dir="$repo_root/packages/pi-opentelemetry"

# jiti version pi pins in its own dependency tree; loading the .ts entry the way
# pi does means using the same transpiler.
jiti_version="${JITI_VERSION:-2.7.0}"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

if [[ ! -f "$pkg_dir/package.json" ]]; then
	echo "pi-package.verify: FAIL package manifest not found at $pkg_dir/package.json" >&2
	echo "  Fix: run this script from a checkout that contains packages/pi-opentelemetry." >&2
	echo "  Then check: ls $pkg_dir/package.json resolves." >&2
	exit 1
fi

# --- Workspace ---------------------------------------------------------------
# One temporary directory holds both the packed tarball and the clean install
# project. It is removed on any exit so a failed run leaves nothing behind.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pi-pkg-verify.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# --- Pack --------------------------------------------------------------------
echo "pi-package.verify: packing $pkg_dir"
tarball_name="$(cd "$pkg_dir" && npm pack --pack-destination "$work_dir" --silent)"
tarball="$work_dir/$tarball_name"
if [[ ! -f "$tarball" ]]; then
	echo "pi-package.verify: FAIL npm pack did not produce a tarball" >&2
	echo "  Fix: run 'cd $pkg_dir && npm pack' and read the error it prints." >&2
	echo "  Then check: the tarball path $tarball exists." >&2
	exit 1
fi

# --- Check 1 and 2: tarball excludes tests and lockfiles ---------------------
# Read the file list once; the tarball paths are prefixed with 'package/'.
contents="$(tar -tzf "$tarball")"

test_hits="$(echo "$contents" | grep -E '\.test\.[cm]?[jt]s$' || true)"
if [[ -n "$test_hits" ]]; then
	echo "pi-package.verify: FAIL the tarball ships test files:" >&2
	indent_lines "$test_hits"
	echo "  Fix: the 'files' list in package.json must exclude src/**/*.test.ts." >&2
	echo "  Then check: 'npm pack --dry-run' lists no .test.ts entry." >&2
	exit 1
fi
echo "pi-package.verify: PASS no test file in the tarball"

lock_hits="$(echo "$contents" | grep -E '(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml)$' || true)"
if [[ -n "$lock_hits" ]]; then
	echo "pi-package.verify: FAIL the tarball ships a lockfile:" >&2
	indent_lines "$lock_hits"
	echo "  Fix: remove the lockfile from the 'files' list; npm never needs a" >&2
	echo "       published lockfile and it pins a consumer's dependency tree." >&2
	echo "  Then check: 'npm pack --dry-run' lists no lockfile." >&2
	exit 1
fi
echo "pi-package.verify: PASS no lockfile in the tarball"

# --- Check 3: the intended files are present ---------------------------------
# npm prefixes every packed path with 'package/'. Confirm the manifest, license,
# readme, and the pi manifest entry all shipped.
missing=""
for required in package/package.json package/README.md package/LICENSE package/src/index.ts; do
	echo "$contents" | grep -qxF "$required" || missing="$missing $required"
done
if [[ -n "$missing" ]]; then
	echo "pi-package.verify: FAIL the tarball is missing intended files:$missing" >&2
	echo "  Fix: the 'files' list in package.json must ship the manifest, README," >&2
	echo "       LICENSE, and the pi entry point and its import graph." >&2
	echo "  Then check: 'npm pack --dry-run' lists each of${missing}." >&2
	exit 1
fi
echo "pi-package.verify: PASS the manifest, README, LICENSE, and entry point are present"

# --- Install into a clean project -------------------------------------------
proj_dir="$work_dir/project"
mkdir -p "$proj_dir"
(
	cd "$proj_dir"
	npm init -y >/dev/null 2>&1
	# Install the tarball (which pulls its own dependencies and peer
	# dependencies) plus jiti, the transpiler pi uses to load a .ts entry.
	npm install --no-audit --no-fund --silent "$tarball" "jiti@$jiti_version"
) || {
	echo "pi-package.verify: FAIL the tarball did not install into a clean project" >&2
	echo "  Fix: run 'npm install $tarball' in an empty directory and read the error." >&2
	echo "  Then check: the install completes and node_modules/@desek/pi-opentelemetry exists." >&2
	exit 1
}

installed_pkg="$proj_dir/node_modules/@desek/pi-opentelemetry"
if [[ ! -d "$installed_pkg" ]]; then
	echo "pi-package.verify: FAIL @desek/pi-opentelemetry is not installed after npm install" >&2
	echo "  Fix: confirm the package name in package.json is @desek/pi-opentelemetry." >&2
	echo "  Then check: ls $installed_pkg resolves." >&2
	exit 1
fi

# --- Check 3 and 4: the manifest entry resolves and loads through jiti -------
# This node module reproduces pi's exact two steps (resolveExtensionEntries then
# loadExtensionModule): read pi.extensions from the installed manifest, resolve
# it against the installed package directory, confirm the file exists, and load
# it through jiti, asserting the module's default export is a factory function.
loader="$proj_dir/load-entry.mjs"
cat >"$loader" <<'NODE'
import * as fs from "node:fs";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import { createJiti } from "jiti/static";

const pkgDir = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
const entries = manifest?.pi?.extensions;
if (!Array.isArray(entries) || entries.length === 0) {
  console.error("no pi.extensions array in the installed manifest");
  process.exit(2);
}
const entry = path.resolve(pkgDir, entries[0]);
if (!fs.existsSync(entry)) {
  console.error(`manifest entry does not exist on disk: ${entries[0]} -> ${entry}`);
  process.exit(3);
}
const jiti = createJiti(pathToFileURL(entry).href, { moduleCache: false });
const factory = await jiti.import(entry, { default: true });
if (typeof factory !== "function") {
  console.error(`manifest entry loaded but its default export is ${typeof factory}, not a function`);
  process.exit(4);
}
console.log(`loaded ${entries[0]} -> ${typeof factory} factory`);
NODE

echo "pi-package.verify: loading the pi manifest entry through jiti@$jiti_version"
if load_out="$(cd "$proj_dir" && node "$loader" "$installed_pkg" 2>&1)"; then
	echo "pi-package.verify: PASS manifest entry resolves on disk"
	echo "pi-package.verify: PASS $load_out"
else
	echo "pi-package.verify: FAIL the pi manifest entry did not load: $load_out" >&2
	echo "  Fix: the 'files' list must ship the whole src/ import graph the entry" >&2
	echo "       needs, and pi.extensions must point at a file inside it." >&2
	echo "  Then check: 'npm pack --dry-run' lists src/index.ts and every module it imports." >&2
	exit 1
fi

echo "pi-package.verify: PASS all checks"

#!/usr/bin/env bash
#
# pi-package.verify.sh
#
# @agents-index Install smoke test for both published pi packages (@desek/pi-opentelemetry and @desek/pi-mlflow-tracing): for each it packs the package, installs the tarball into a clean temporary project, loads the pi manifest entry through jiti exactly as pi does, and asserts the tarball ships no test file and no lockfile.
#
# Purpose: prove that a registry-installed tarball is not a silent no-op. A pi
# package's worst failure is installing cleanly while shipping an incomplete
# import graph, so pi finds the manifest entry, loads nothing, and stays quiet.
# This script closes that gap the way a user hits it, for every pi package the
# repository publishes, asserting four facts per package, each reported as its own
# check:
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
# Why both packages: the repository publishes two pi extensions,
# @desek/pi-opentelemetry (metrics, logs, and traces over OTLP) and
# @desek/pi-mlflow-tracing (conversation traces to MLflow). Both are installed
# and loaded by pi the same way, so both must clear the same smoke test; checking
# only one would let a packaging defect in the other reach a user.
#
# Usage:
#   scripts/pi-package.verify.sh      Pack, install into a clean dir, and load,
#                                     for every pi package in the repository.
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
# Resolve the repository root from the script location so the checks run the same
# way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# The published pi packages, by directory name under packages/. Each is verified
# in turn; add a package here and it is covered by the same smoke test.
PI_PACKAGES=(pi-opentelemetry pi-mlflow-tracing)

# jiti version pi pins in its own dependency tree; loading the .ts entry the way
# pi does means using the same transpiler.
jiti_version="${JITI_VERSION:-2.7.0}"

# The temporary workspace of the package currently under test. A single EXIT trap
# removes it, so a failure (which exits the whole script, not just the function)
# leaves nothing behind. It is emptied once a package's own cleanup has run.
current_work_dir=""
cleanup() {
	if [ -n "$current_work_dir" ]; then
		rm -rf "$current_work_dir"
	fi
	# Always succeed: this runs as the EXIT trap, whose exit status becomes the
	# script's, so a false test here must not turn a passing run into a failure.
	return 0
}
trap cleanup EXIT

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

# --- Per-package verification ------------------------------------------------
# Verify one pi package end to end: pack it, assert the tarball excludes tests
# and lockfiles and ships the intended files, install it into a clean project,
# and load its pi manifest entry through jiti. Exits non-zero on the first
# failure. Arguments: the package directory name under packages/.
verify_package() {
	local pkg_name="$1"
	local pkg_dir="$repo_root/packages/$pkg_name"

	echo "pi-package.verify: === $pkg_name ==="

	if [[ ! -f "$pkg_dir/package.json" ]]; then
		echo "pi-package.verify: FAIL package manifest not found at $pkg_dir/package.json" >&2
		echo "  Fix: run this script from a checkout that contains packages/$pkg_name." >&2
		echo "  Then check: ls $pkg_dir/package.json resolves." >&2
		exit 1
	fi

	# The npm package name, read from the manifest, so install and resolution use
	# the real published name rather than the directory name.
	local npm_name
	npm_name="$(node -p "require('$pkg_dir/package.json').name")"

	# --- Workspace -----------------------------------------------------------
	# One temporary directory holds both the packed tarball and the clean install
	# project. It is removed on return so a failed run leaves nothing behind.
	local work_dir
	work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pi-pkg-verify.XXXXXX")"
	current_work_dir="$work_dir"

	# --- Pack ----------------------------------------------------------------
	echo "pi-package.verify: packing $pkg_dir"
	local tarball_name tarball
	tarball_name="$(cd "$pkg_dir" && npm pack --pack-destination "$work_dir" --silent)"
	tarball="$work_dir/$tarball_name"
	if [[ ! -f "$tarball" ]]; then
		echo "pi-package.verify: FAIL npm pack did not produce a tarball" >&2
		echo "  Fix: run 'cd $pkg_dir && npm pack' and read the error it prints." >&2
		echo "  Then check: the tarball path $tarball exists." >&2
		exit 1
	fi

	# --- Check 1 and 2: tarball excludes tests and lockfiles -----------------
	# Read the file list once; the tarball paths are prefixed with 'package/'.
	local contents test_hits lock_hits
	contents="$(tar -tzf "$tarball")"

	test_hits="$(echo "$contents" | grep -E '\.test\.[cm]?[jt]s$' || true)"
	if [[ -n "$test_hits" ]]; then
		echo "pi-package.verify: FAIL the $npm_name tarball ships test files:" >&2
		indent_lines "$test_hits"
		echo "  Fix: the 'files' list in package.json must exclude src/**/*.test.ts." >&2
		echo "  Then check: 'npm pack --dry-run' lists no .test.ts entry." >&2
		exit 1
	fi
	echo "pi-package.verify: PASS no test file in the $npm_name tarball"

	lock_hits="$(echo "$contents" | grep -E '(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml)$' || true)"
	if [[ -n "$lock_hits" ]]; then
		echo "pi-package.verify: FAIL the $npm_name tarball ships a lockfile:" >&2
		indent_lines "$lock_hits"
		echo "  Fix: remove the lockfile from the 'files' list; npm never needs a" >&2
		echo "       published lockfile and it pins a consumer's dependency tree." >&2
		echo "  Then check: 'npm pack --dry-run' lists no lockfile." >&2
		exit 1
	fi
	echo "pi-package.verify: PASS no lockfile in the $npm_name tarball"

	# --- Check 3: the intended files are present -----------------------------
	# npm prefixes every packed path with 'package/'. Confirm the manifest,
	# license, readme, and the pi manifest entry all shipped.
	local missing="" required
	for required in package/package.json package/README.md package/LICENSE package/src/index.ts; do
		echo "$contents" | grep -qxF "$required" || missing="$missing $required"
	done
	if [[ -n "$missing" ]]; then
		echo "pi-package.verify: FAIL the $npm_name tarball is missing intended files:$missing" >&2
		echo "  Fix: the 'files' list in package.json must ship the manifest, README," >&2
		echo "       LICENSE, and the pi entry point and its import graph." >&2
		echo "  Then check: 'npm pack --dry-run' lists each of${missing}." >&2
		exit 1
	fi
	echo "pi-package.verify: PASS the $npm_name manifest, README, LICENSE, and entry point are present"

	# --- Install into a clean project ----------------------------------------
	local proj_dir="$work_dir/project"
	mkdir -p "$proj_dir"
	(
		cd "$proj_dir"
		npm init -y >/dev/null 2>&1
		# Install the tarball (which pulls its own dependencies and peer
		# dependencies) plus jiti, the transpiler pi uses to load a .ts entry.
		npm install --no-audit --no-fund --silent "$tarball" "jiti@$jiti_version"
	) || {
		echo "pi-package.verify: FAIL the $npm_name tarball did not install into a clean project" >&2
		echo "  Fix: run 'npm install $tarball' in an empty directory and read the error." >&2
		echo "  Then check: the install completes and node_modules/$npm_name exists." >&2
		exit 1
	}

	local installed_pkg="$proj_dir/node_modules/$npm_name"
	if [[ ! -d "$installed_pkg" ]]; then
		echo "pi-package.verify: FAIL $npm_name is not installed after npm install" >&2
		echo "  Fix: confirm the package name in package.json is $npm_name." >&2
		echo "  Then check: ls $installed_pkg resolves." >&2
		exit 1
	fi

	# --- Check 3 and 4: the manifest entry resolves and loads through jiti ----
	# This node module reproduces pi's exact two steps (resolveExtensionEntries
	# then loadExtensionModule): read pi.extensions from the installed manifest,
	# resolve it against the installed package directory, confirm the file exists,
	# and load it through jiti, asserting the module's default export is a factory.
	local loader="$proj_dir/load-entry.mjs"
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

	echo "pi-package.verify: loading the $npm_name manifest entry through jiti@$jiti_version"
	local load_out
	if load_out="$(cd "$proj_dir" && node "$loader" "$installed_pkg" 2>&1)"; then
		echo "pi-package.verify: PASS $npm_name manifest entry resolves on disk"
		echo "pi-package.verify: PASS $load_out"
	else
		echo "pi-package.verify: FAIL the $npm_name pi manifest entry did not load: $load_out" >&2
		echo "  Fix: the 'files' list must ship the whole src/ import graph the entry" >&2
		echo "       needs, and pi.extensions must point at a file inside it." >&2
		echo "  Then check: 'npm pack --dry-run' lists src/index.ts and every module it imports." >&2
		exit 1
	fi

	# Drop the per-package workspace now, so two packages never hold two temp
	# trees at once, and clear the tracked path so the EXIT trap has nothing left.
	rm -rf "$work_dir"
	current_work_dir=""
	echo "pi-package.verify: PASS $npm_name"
}

for pkg in "${PI_PACKAGES[@]}"; do
	verify_package "$pkg"
done

echo "pi-package.verify: PASS all checks for all packages"

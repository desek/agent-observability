#!/usr/bin/env bash
#
# release.config.verify.sh
#
# @agents-index Validates the release-please configuration against the packages on disk: every package under packages/ is declared, every declared path exists, the release manifest and each package.json version agree (a 0.0.0 manifest entry is the never-published sentinel and is exempt), and both JSON files parse.
#
# Purpose: keep the single statement of which packages this repository releases,
# release-please-config.json, in agreement with the packages that actually exist
# on disk and with the versions release-please starts each of them from. A
# package added under packages/ without a configuration entry is silently
# unreleasable; this script turns that silence into a failed check. It reads only
# files in the checkout, needs no network and no running stack, and is meant to
# run in `make ci` regardless of stack state.
#
# It asserts four facts, each reported as its own check:
#   1. Both files parse. release-please-config.json and
#      .release-please-manifest.json are valid JSON.
#   2. Every package is declared. Each directory under packages/ that has a
#      package.json appears in the configuration's packages map.
#   3. Every declared package exists. Each configured path is a directory on disk
#      with a package.json.
#   4. The manifest and the package versions agree. Each configured package has a
#      manifest entry, and it equals that package's package.json version. The one
#      exemption: a manifest entry of 0.0.0 is the never-published sentinel (a
#      package that exists on disk but has never reached the registry, seeded at
#      0.0.0 on purpose so the automation computes its on-disk version as an
#      ordinary first release rather than treating it as already released). Such
#      an entry is accepted whatever the on-disk version is.
#
# The script exits non-zero on the first failure. Every failure names what
# failed, the fix available, and what to check after the fix.
#
# Usage:
#   scripts/release.config.verify.sh            Print this usage and exit 0.
#   scripts/release.config.verify.sh -h         Print this usage and exit 0.
#   scripts/release.config.verify.sh --help     Print this usage and exit 0.
#   scripts/release.config.verify.sh check      Run every check; exit non-zero on
#                                               the first failure, 0 if all pass.
#
# Running with no argument prints this usage and exits 0 on purpose, so the check
# is only ever performed when it is asked for by name. `make ci` calls it as
# `release.config.verify.sh check`.
#
# Parameters:
#   check        Run the validation checks.
#   -h, --help   Print usage and exit 0.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the checks run the same
# way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

config_file="$repo_root/release-please-config.json"
manifest_file="$repo_root/.release-please-manifest.json"
packages_dir="$repo_root/packages"

# The manifest version that marks a package as never published. Seeding an
# unpublished package here makes release-please compute its first release from
# the commits rather than treat its on-disk version as already released, so this
# value is exempt from the version-agreement check on purpose.
NEVER_PUBLISHED="0.0.0"

# --- Usage -------------------------------------------------------------------
# Print the top-of-file docstring as usage text, stripping the leading comment
# markers. Keeps usage and documentation from drifting apart.
usage() {
	sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Checks ------------------------------------------------------------------

# Check 1: both files parse as valid JSON. Every later check reads them, so a
# parse failure is reported first and stops the run. Arguments: none.
check_files_parse() {
	local f err
	err="$(mktemp)"
	for f in "$config_file" "$manifest_file"; do
		if [[ ! -f "$f" ]]; then
			echo "release.config.verify: FAIL required file not found: $f" >&2
			echo "  Fix: this file is part of the release automation; restore it from" >&2
			echo "       version control or add it (the release automation needs both)." >&2
			echo "  Then check: ls $f resolves." >&2
			rm -f "$err"
			exit 1
		fi
		if ! jq empty "$f" 2>"$err"; then
			echo "release.config.verify: FAIL $f is not valid JSON:" >&2
			sed 's/^/    /' "$err" >&2 || true
			rm -f "$err"
			echo "  Fix: correct the JSON syntax the parser named above." >&2
			echo "  Then check: 'jq empty $f' exits 0." >&2
			exit 1
		fi
	done
	rm -f "$err"
	echo "release.config.verify: PASS both files parse as valid JSON"
}

# Check 2: every package on disk is declared in the configuration. A package
# directory with a package.json but no configuration entry is silently
# unreleasable, so it fails here. Arguments: none.
check_every_package_declared() {
	local dir pkg_path undeclared=""
	for dir in "$packages_dir"/*/; do
		[[ -f "${dir}package.json" ]] || continue
		# The configuration keys packages by their repo-relative path.
		pkg_path="packages/$(basename "$dir")"
		if ! jq -e --arg p "$pkg_path" '.packages | has($p)' "$config_file" >/dev/null; then
			undeclared="$undeclared $pkg_path"
		fi
	done
	if [[ -n "$undeclared" ]]; then
		echo "release.config.verify: FAIL these packages exist on disk but are not declared:$undeclared" >&2
		echo "  Fix: add each to the 'packages' map in release-please-config.json, e.g." >&2
		echo "       \"packages/<name>\": { \"release-type\": \"node\" }, and record its" >&2
		echo "       version in .release-please-manifest.json (0.0.0 if never published)." >&2
		echo "  Then check: this script's 'check' run passes for the added package." >&2
		exit 1
	fi
	echo "release.config.verify: PASS every package under packages/ is declared"
}

# Check 3: every declared path exists on disk with a package.json. A
# configuration entry that names a path with no package is a dangling reference
# the automation would fail on, so it fails here. Arguments: none.
check_every_declared_exists() {
	local pkg_path missing=""
	while IFS= read -r pkg_path; do
		if [[ ! -f "$repo_root/$pkg_path/package.json" ]]; then
			missing="$missing $pkg_path"
		fi
	done < <(jq -r '.packages | keys[]' "$config_file")
	if [[ -n "$missing" ]]; then
		echo "release.config.verify: FAIL these declared paths have no package on disk:$missing" >&2
		echo "  Fix: either restore the package directory and its package.json, or" >&2
		echo "       remove the stale entry from the 'packages' map in" >&2
		echo "       release-please-config.json and .release-please-manifest.json." >&2
		echo "  Then check: ls <path>/package.json resolves for each declared path." >&2
		exit 1
	fi
	echo "release.config.verify: PASS every declared package exists on disk"
}

# Check 4: the release manifest and each package's package.json version agree.
# Each configured package must have a manifest entry equal to its on-disk
# version, with the never-published sentinel (0.0.0) exempt. Arguments: none.
check_versions_agree() {
	local pkg_path manifest_version disk_version
	while IFS= read -r pkg_path; do
		# The manifest entry must be present: it is the version release-please
		# starts this package from, and NFR1 requires the manifest and the
		# configuration to name the same packages.
		if ! jq -e --arg p "$pkg_path" 'has($p)' "$manifest_file" >/dev/null; then
			echo "release.config.verify: FAIL $pkg_path is declared but has no manifest entry" >&2
			echo "  Fix: add \"$pkg_path\": \"<version>\" to .release-please-manifest.json." >&2
			echo "       Use the published version, or $NEVER_PUBLISHED if never published." >&2
			echo "  Then check: jq --arg p '$pkg_path' '.[\$p]' .release-please-manifest.json prints a version." >&2
			exit 1
		fi
		manifest_version="$(jq -r --arg p "$pkg_path" '.[$p]' "$manifest_file")"

		# A 0.0.0 manifest entry marks a package that exists on disk but has never
		# been published; the automation will compute its first release from the
		# commits, so its on-disk version is expected to differ and is not an error.
		if [[ "$manifest_version" == "$NEVER_PUBLISHED" ]]; then
			disk_version="$(jq -r '.version // "unset"' "$repo_root/$pkg_path/package.json")"
			echo "release.config.verify: PASS $pkg_path seeded as never-published ($NEVER_PUBLISHED); on-disk $disk_version will be proposed as its first release"
			continue
		fi

		if ! jq -e 'has("version")' "$repo_root/$pkg_path/package.json" >/dev/null; then
			echo "release.config.verify: FAIL $pkg_path/package.json has no version field" >&2
			echo "  Fix: add a \"version\" field to $pkg_path/package.json." >&2
			echo "  Then check: jq .version $pkg_path/package.json prints a version." >&2
			exit 1
		fi
		disk_version="$(jq -r '.version' "$repo_root/$pkg_path/package.json")"

		if [[ "$manifest_version" != "$disk_version" ]]; then
			echo "release.config.verify: FAIL version disagreement for $pkg_path:" >&2
			echo "    .release-please-manifest.json says $manifest_version" >&2
			echo "    $pkg_path/package.json says       $disk_version" >&2
			echo "  Fix: for an already-published package, set the manifest entry to the" >&2
			echo "       package.json version (the version last released). For a package" >&2
			echo "       never published, set the manifest entry to $NEVER_PUBLISHED so the" >&2
			echo "       automation proposes the on-disk version as a first release." >&2
			echo "  Then check: the manifest entry matches the package.json version, or is $NEVER_PUBLISHED." >&2
			exit 1
		fi
		echo "release.config.verify: PASS $pkg_path manifest and package version agree ($manifest_version)"
	done < <(jq -r '.packages | keys[]' "$config_file")
}

# --- Entry point -------------------------------------------------------------
case "${1:-}" in
	check)
		check_files_parse
		check_every_package_declared
		check_every_declared_exists
		check_versions_agree
		echo "release.config.verify: PASS all checks"
		;;
	-h | --help | "")
		usage
		exit 0
		;;
	*)
		echo "release.config.verify: unknown argument '$1'" >&2
		echo >&2
		usage >&2
		exit 2
		;;
esac

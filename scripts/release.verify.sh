#!/usr/bin/env bash
#
# release.verify.sh
#
# @agents-index Verifies a completed release from outside the repository: the component tag exists on the remote, the GitHub release exists, the version is on the npm registry, and the published artifact carries trusted-publishing provenance; an unreleased version fails rather than passing quietly.
#
# Purpose: prove that a release actually landed everywhere it should have, from
# the outside, using only what a consumer or an auditor can see. A release is not
# finished when a pull request merges; it is finished when the tag and the
# release exist on the remote and the version is on the registry with provenance
# attached by the trusted-publishing path. This script asserts all four, so a
# half-completed release (a tag with no publish, a publish with no provenance, a
# version that was never released) fails a check rather than being assumed done.
#
# It reads nothing from the working tree except the remote URL of this clone,
# which it uses only to name the GitHub repository to query. Everything it
# asserts comes from the GitHub API and the npm registry, so it verifies the
# real, published state rather than the local checkout.
#
# It asserts four facts, each reported as its own check, matching the four rows
# the change request names for this script:
#   1. The tag and the release exist. The component tag <component>-v<version>
#      resolves on the remote, and a GitHub release exists for it.
#   2. The version is on the registry. The npm registry returns the version
#      manifest for the released version.
#   3. The artifact carries provenance. That version manifest carries a
#      dist.attestations block, which is what the trusted-publishing path
#      attaches and a hand publish does not.
#   4. A missing release fails. A version that was never released fails these
#      checks with a non-zero exit that names what was absent, so an unreleased
#      version cannot pass quietly.
#
# The tag form is <component>-v<version>, where the component is the npm package
# name with its scope removed (so @desek/pi-opentelemetry has component
# pi-opentelemetry and tag pi-opentelemetry-v0.1.1). The bare v<version> tag form
# is retired and is not checked. Publication happens inside
# .github/workflows/release.yml in the same run as the release, so a release that
# exists but was never published is the exact failure this script is built to
# catch.
#
# The script exits non-zero on the first failure. Every failure names what
# failed, the fixes available, and what to check after the fix.
#
# Usage:
#   scripts/release.verify.sh                       Print this usage and exit 0.
#   scripts/release.verify.sh -h                    Print this usage and exit 0.
#   scripts/release.verify.sh --help                Print this usage and exit 0.
#   scripts/release.verify.sh <package> <version>   Verify that release.
#
# Running with no argument prints this usage and exits 0 on purpose, so the check
# is only ever performed when it is asked for by name with a package and version.
#
# Parameters:
#   <package>    The npm package name, scope included, e.g. @desek/pi-opentelemetry.
#   <version>    The released version, e.g. 0.1.1.
#   -h, --help   Print usage and exit 0.
#
# Environment:
#   RELEASE_REPO   The GitHub repository to query, as owner/name. Read from the
#                  shell first, then derived from this clone's origin remote.
#                  Set it when running from a checkout whose origin is not the
#                  repository that holds the release.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the remote lookup works
# the same way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

readonly REGISTRY="https://registry.npmjs.org"

# --- Usage -------------------------------------------------------------------
# Print the top-of-file docstring as usage text, stripping the leading comment
# markers. Keeps usage and documentation from drifting apart.
usage() {
	sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Reporting helpers -------------------------------------------------------
# Every failure names what failed, the fixes available, and what to check after.
fail() {
	local what="$1" fix="$2" after="$3"
	echo "release-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}
pass() { echo "release-verify: PASS $1"; }

# --- Prerequisites -----------------------------------------------------------
# The script queries GitHub with gh and the registry with curl, and parses JSON
# with jq. A missing tool is named with how to get it, not a bare command-not-found.
require_tool() {
	local tool="$1" why="$2" how="$3"
	command -v "$tool" >/dev/null 2>&1 || fail \
		"required tool '$tool' is not on PATH ($why)." \
		"install $tool; $how" \
		"re-run this script once '$tool' resolves."
}

# --- Repository resolution ---------------------------------------------------
# The GitHub repository to query, as owner/name. Prefer an explicit RELEASE_REPO,
# then derive it from this clone's origin remote, parsing both SSH and HTTPS forms.
resolve_repo() {
	local repo="${RELEASE_REPO:-}"
	if [[ -z "$repo" ]]; then
		local url
		url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
		[[ -n "$url" ]] || fail \
			"cannot determine the GitHub repository to query." \
			"set RELEASE_REPO=owner/name, or run from a clone whose origin remote points at the release repository." \
			"re-run with RELEASE_REPO set, e.g. RELEASE_REPO=desek/agent-observability."
		# Strip the transport prefix, the trailing .git, and normalise the SSH
		# host:owner/name form to owner/name.
		repo="${url#git@github.com:}"
		repo="${repo#https://github.com/}"
		repo="${repo#ssh://git@github.com/}"
		repo="${repo%.git}"
	fi
	printf '%s' "$repo"
}

# --- Checks ------------------------------------------------------------------

# Check 1: the component tag and the GitHub release both exist. A tag without a
# release, or neither, is an incomplete release and fails here.
# Arguments: repo, tag.
check_tag_and_release() {
	local repo="$1" tag="$2"

	# The tag ref resolves on the remote. A 404 here means the release pull
	# request was never merged, or was merged without cutting a tag.
	if ! gh api "repos/$repo/git/ref/tags/$tag" >/dev/null 2>&1; then
		fail \
			"tag '$tag' does not exist on $repo." \
			"merge the release pull request for this package so release-please cuts the component tag, or check the version and package you passed. The tag form is <component>-v<version> with the scope stripped from the package name; the bare v<version> form is retired and not used." \
			"re-run this script and confirm 'gh api repos/$repo/git/ref/tags/$tag' returns the ref."
	fi

	# The GitHub release for that tag exists. release-please creates the release
	# alongside the tag, so a tag with no release means the release step did not
	# complete.
	if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
		fail \
			"the tag '$tag' exists on $repo but there is no GitHub release for it." \
			"a merged release pull request creates the tag and the release together; inspect the release workflow run for the release-please job and re-run it if the release step failed after the tag was pushed." \
			"re-run this script and confirm 'gh release view $tag --repo $repo' shows the release."
	fi

	pass "tag '$tag' and its GitHub release exist on $repo."
}

# Check 2 and 3: the version is on the npm registry, and the published artifact
# carries trusted-publishing provenance. These are read together from the one
# version manifest the registry returns. Arguments: package, version.
check_registry_and_provenance() {
	local package="$1" version="$2"
	local encoded status body

	# The registry keys a scoped name with the slash percent-encoded.
	encoded="${package/\//%2F}"

	status="$(curl -s -o /dev/null -w '%{http_code}' "$REGISTRY/$encoded/$version")"
	if [[ "$status" != "200" ]]; then
		fail \
			"$package@$version is not on the npm registry (registry returned $status)." \
			"publication happens in the same release workflow run as the release, gated on release-please's released-paths output; if the tag and release exist but this version is absent, inspect the publish job of that run. For a package publishing for the very first time, confirm the one-time human step is done: the registry package and its trusted-publishing relationship must exist, and the relationship must name .github/workflows/release.yml." \
			"re-run this script and confirm '$REGISTRY/$encoded/$version' returns HTTP 200."
	fi
	pass "$package@$version is on the npm registry."

	# The version manifest carries a dist.attestations block only when the
	# artifact was published over the trusted-publishing path, which attaches
	# provenance. A hand publish has no attestations, so its absence is a real
	# finding, not a formatting quirk.
	body="$(curl -s "$REGISTRY/$encoded/$version")"
	if ! printf '%s' "$body" | jq -e '.dist.attestations // empty' >/dev/null 2>&1; then
		fail \
			"$package@$version is published but carries no provenance (no dist.attestations)." \
			"publish over the trusted-publishing path so the registry attaches provenance: the publish job in .github/workflows/release.yml holds id-token: write and runs npm publish with no stored token. A version published by hand has no provenance and cannot gain it retroactively; publish a new patch through the release workflow instead." \
			"re-run this script and confirm the version manifest at $REGISTRY/$encoded/$version has a dist.attestations block."
	fi
	pass "$package@$version carries trusted-publishing provenance."
}

# --- Entry point -------------------------------------------------------------
case "${1:-}" in
	-h | --help | "")
		usage
		exit 0
		;;
esac

if [[ "$#" -ne 2 ]]; then
	echo "release-verify: FAIL expected a package and a version, got $# argument(s)." >&2
	echo >&2
	usage >&2
	exit 2
fi

package="$1"
version="$2"

# The component is the package name with its scope removed; the tag carries it.
component="${package##*/}"
tag="${component}-v${version}"

require_tool gh "queries the GitHub API for the tag and the release" \
	"see https://cli.github.com and authenticate with 'gh auth login'."
require_tool curl "queries the npm registry for the version and its provenance" \
	"install it with your system package manager."
require_tool jq "parses the registry response for the provenance block" \
	"install it with your system package manager."

repo="$(resolve_repo)"

echo "release-verify: verifying $package@$version"
echo "release-verify: repository $repo, tag $tag"

check_tag_and_release "$repo" "$tag"
check_registry_and_provenance "$package" "$version"

echo "release-verify: PASS $package@$version is fully released (tag, release, registry, provenance)"

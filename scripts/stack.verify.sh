#!/usr/bin/env bash
#
# stack.verify.sh
#
# @agents-index Outside-in verifier that proves the running stack in one run: one loopback host port, six readiness endpoints, three healthy datasources, no parent references, no floating image tags.
#
# Purpose: prove the stack from the outside, the way a user reaches it, in a
# single run. It asserts five facts, each reported as its own check:
#   1. Exactly one service publishes a host port, and it binds 127.0.0.1.
#   2. All six endpoints answer through that single port.
#   3. The three Grafana datasources exist and their health checks pass.
#   4. No tracked file outside docs references a parent-only path or a
#      governance identifier.
#   5. No image reference in compose.yaml uses the floating latest tag.
# The script exits non-zero on the first failure. Every failure names what
# failed, the fix, and what to check after the fix.
#
# Usage:
#   scripts/stack.verify.sh          Run every check against the running stack.
#   scripts/stack.verify.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0. The script takes no other argument.
#
# Environment:
#   EDGE_PORT        Loopback host port the edge proxy publishes. Read from the
#                    shell first, then from .env, then defaults to 24317.
#   GRAFANA_USER     Grafana API user for the datasource health check. Default admin.
#   GRAFANA_PASSWORD Grafana API password. Default admin.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the checks run the
# same way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/stack.verify.sh' with no argument, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

# --- Port resolution ---------------------------------------------------------
# The shell environment wins, then .env, then the default. This matches how
# docker compose resolves EDGE_PORT, so the script and the stack never disagree.
# Only the EDGE_PORT line is read from .env, so no other value in that file is
# touched.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://127.0.0.1:${edge_port}"
grafana_user="${GRAFANA_USER:-admin}"
grafana_password="${GRAFANA_PASSWORD:-admin}"

# --- Reporting helpers -------------------------------------------------------
# pass prints a single confirmation line. fail prints the three-part actionable
# message (what failed, the fix, what to check after) and exits non-zero on the
# first failure.
pass() {
	echo "verify: PASS $1"
}

fail() {
	local what="$1" fix="$2" after="$3"
	echo "verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# http_status prints the HTTP status code for a GET on the given path, or 000
# when the connection does not answer at all.
http_status() {
	local path="$1"
	curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${base_url}${path}" || true
}

# --- Check 1: exactly one published host port, bound to loopback -------------
# docker port prints a binding line only for a port that is actually published
# to the host. An exposed-only port prints nothing. So the count of containers
# with a non-empty docker port output is the count of published services.
check_single_published_port() {
	local names published=() name binding host
	mapfile -t names < <(docker compose ps --format '{{.Name}}' 2>/dev/null)
	if [ "${#names[@]}" -eq 0 ]; then
		fail "no stack containers are running." \
			"start the stack with 'scripts/stack.up.sh'." \
			"re-run 'scripts/stack.verify.sh' once every service is up."
	fi
	for name in "${names[@]}"; do
		binding="$(docker port "$name" 2>/dev/null || true)"
		if [ -n "$binding" ]; then
			published+=("$name")
		fi
	done
	if [ "${#published[@]}" -ne 1 ]; then
		fail "expected exactly one service to publish a host port, found ${#published[@]} (${published[*]:-none})." \
			"remove every 'ports:' mapping in compose.yaml except the one on the haproxy service." \
			"re-run 'docker compose up -d' then this script, and confirm only haproxy is listed."
	fi
	host="$(docker port "${published[0]}" | head -n1 | sed 's/.*-> //; s/:[0-9]*$//')"
	if [ "$host" != "127.0.0.1" ]; then
		fail "the published port on '${published[0]}' binds '$host', not loopback." \
			"set the haproxy 'ports:' mapping to '127.0.0.1:\${EDGE_PORT:-24317}:24317' in compose.yaml." \
			"re-run 'docker compose up -d' then this script, and confirm the binding host is 127.0.0.1."
	fi
	pass "one published host port on '${published[0]}', bound to 127.0.0.1."
}

# --- Check 2: every endpoint answers through the single port -----------------
check_endpoints() {
	local pairs=(
		"/loki/ready|loki"
		"/prometheus/ready|mimir"
		"/tempo/ready|tempo"
		"/alloy/-/healthy|alloy"
		"/api/health|grafana"
		"/mlflow/health|mlflow"
	)
	local pair path service code
	for pair in "${pairs[@]}"; do
		path="${pair%%|*}"
		service="${pair##*|}"
		code="$(http_status "$path")"
		if [ "$code" != "200" ]; then
			fail "endpoint '${path}' returned '${code}', not 200, through port ${edge_port}." \
				"the '${service}' backend is not answering; restart it with 'docker compose up -d ${service}' and check its log with 'docker compose logs ${service}'." \
				"re-run 'scripts/stack.verify.sh' and confirm '${path}' returns 200."
		fi
	done
	pass "all six endpoints answer 200 through port ${edge_port}."
}

# --- Check 3: the three Grafana datasources exist and are healthy ------------
check_datasources() {
	local uids=(mimir loki tempo) uid code body
	for uid in "${uids[@]}"; do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
			-u "${grafana_user}:${grafana_password}" \
			"${base_url}/api/datasources/uid/${uid}/health" || true)"
		if [ "$code" = "404" ]; then
			fail "the '${uid}' datasource is not provisioned in Grafana." \
				"confirm 'stack/grafana/provisioning/datasources/datasources.yaml' defines uid '${uid}' and re-provision with 'docker compose up -d grafana'." \
				"re-run 'scripts/stack.verify.sh' and confirm the '${uid}' datasource is present."
		fi
		if [ "$code" != "200" ]; then
			fail "the Grafana datasource health API returned '${code}' for '${uid}'." \
				"confirm Grafana answers on port ${edge_port} and that GRAFANA_USER and GRAFANA_PASSWORD are correct (default admin and admin)." \
				"re-run 'scripts/stack.verify.sh' and confirm the API returns 200 for '${uid}'."
		fi
		body="$(curl -s --max-time 10 -u "${grafana_user}:${grafana_password}" \
			"${base_url}/api/datasources/uid/${uid}/health" || true)"
		if ! printf '%s' "$body" | grep -qE '"status"[[:space:]]*:[[:space:]]*"OK"'; then
			fail "the '${uid}' datasource health check did not report OK." \
				"confirm the '${uid}' backend is ready with 'scripts/stack.verify.sh' check 2, then check the backend log with 'docker compose logs ${uid}'." \
				"re-run 'scripts/stack.verify.sh' and confirm '${uid}' reports status OK."
		fi
	done
	pass "the mimir, loki, and tempo datasources exist and report healthy."
}

# --- Check 4: no parent references and no governance identifiers -------------
# The scan covers tracked files outside docs. The governance record under docs
# is allowed to describe the parent it migrated from and to carry its own
# identifier, so docs is excluded by design. This verifier itself holds the
# search patterns as literal text, so it is excluded from its own parent-path
# scan to avoid a self-match.
check_no_parent_references() {
	local parent_hits gov_hits
	parent_hits="$(git grep -nE 'pi-extensions/|link-pi\.sh|link-claude\.sh|agent-orchestration' \
		-- ':!docs' ':!scripts/stack.verify.sh' || true)"
	if [ -n "$parent_hits" ]; then
		echo "$parent_hits" >&2
		fail "a tracked file outside docs references a parent-only path (listed above)." \
			"replace each reference with a path inside this repository, or remove it." \
			"re-run 'scripts/stack.verify.sh' and confirm the parent-path scan is empty."
	fi
	gov_hits="$(git grep -nE 'CR-[0-9][0-9][0-9][0-9]' -- ':!docs' || true)"
	if [ -n "$gov_hits" ]; then
		echo "$gov_hits" >&2
		fail "a tracked file outside docs carries a governance identifier (listed above)." \
			"strip the identifier from the file while keeping the explanation it introduced." \
			"re-run 'scripts/stack.verify.sh' and confirm the identifier scan is empty."
	fi
	pass "no parent references and no governance identifiers outside docs."
}

# --- Check 5: no floating latest image tag -----------------------------------
check_pinned_images() {
	local hits
	hits="$(grep -nE '^[[:space:]]*image:.*:latest([[:space:]]|$)' "$repo_root/compose.yaml" || true)"
	if [ -n "$hits" ]; then
		echo "$hits" >&2
		fail "an image reference in compose.yaml uses the floating latest tag (listed above)." \
			"pin the image to an explicit published version tag." \
			"re-run 'scripts/stack.verify.sh' and confirm no image uses latest."
	fi
	pass "every image reference in compose.yaml is pinned to an explicit tag."
}

# --- Run every check in order ------------------------------------------------
echo "verify: checking the stack on port ${edge_port}"
check_single_published_port
check_endpoints
check_datasources
check_no_parent_references
check_pinned_images
echo "verify: all checks passed"

#!/usr/bin/env bash
#
# rules.provision.sh
#
# @agents-index Uploads this repository's Mimir recording rules through the single edge port, so the continuous series that make agent telemetry explorable exist on a fresh clone without anyone knowing to create them.
#
# Purpose: the agent counters are short-lived per-session series, so every query
# built on growth returns nothing and tools like Grafana's Metrics Drilldown show
# "No data" for the whole stack. The rules in stack/mimir/rules turn those
# counters into continuous series. This script loads them.
#
# Why a script and not a mounted file: Mimir's filesystem ruler backend expects a
# tenant-scoped layout under its data directory, which is a volume rather than a
# bind mount, so a rule file committed to this repository cannot simply appear
# there. The ruler's configuration API is the supported route, it is idempotent,
# and it works the same whether the stack is fresh or already running.
#
# Usage:
#   scripts/rules.provision.sh          Upload every rule group.
#   scripts/rules.provision.sh --list   Show the rule groups currently loaded.
#   scripts/rules.provision.sh -h       Print this usage and exit 0.
#
# Environment:
#   EDGE_PORT   Loopback host port the edge proxy publishes. Read from the shell
#               first, then from .env, then defaults to 24317.
#
# Exit status: 0 on success; non-zero on the first failure, with a message that
# names what failed, the fix, and what to check after.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
readonly RULES_DIR="stack/mimir/rules"
# Mimir groups rules under a namespace. One namespace keeps a re-upload a
# replacement of the whole set rather than an accumulation of stale groups.
readonly NAMESPACE="agent-observability"

usage() { sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

info() { echo "rules: $1"; }
pass() { echo "rules: PASS $1"; }
fail() {
	local what="$1" fix="$2" after="$3"
	echo "rules: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

cd "$repo_root"

resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://127.0.0.1:${edge_port}"

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	--list)
		curl -s --max-time 15 "${base_url}/prometheus/config/v1/rules" || true
		exit 0
		;;
	"") ;;
	*)
		echo "rules: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/rules.provision.sh', '--list', or '-h'." >&2
		echo "  After: re-run with a supported argument." >&2
		exit 2
		;;
esac

command -v curl >/dev/null 2>&1 || fail "curl is not installed." \
	"install curl; this script talks to the ruler over HTTP." \
	"re-run 'scripts/rules.provision.sh' once curl is on PATH."

shopt -s nullglob
files=("$RULES_DIR"/*.yaml)
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] || fail \
	"no rule files were found under ${RULES_DIR}." \
	"add a rule group there, or restore the committed one." \
	"re-run 'scripts/rules.provision.sh' once a rule file exists."

# The ruler must answer before an upload is attempted, otherwise a failure here
# reads as a bad rule file rather than a stack that is not up.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${base_url}/prometheus/config/v1/rules" || true)"
[ "$code" = "200" ] || fail \
	"the ruler did not answer on port ${edge_port} (returned '${code}')." \
	"start the stack with 'scripts/stack.up.sh' and confirm it is healthy with 'scripts/stack.verify.sh'." \
	"re-run 'scripts/rules.provision.sh' once the ruler answers 200."

for f in "${files[@]}"; do
	info "uploading $(basename "$f") into namespace ${NAMESPACE}"
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
		-X POST "${base_url}/prometheus/config/v1/rules/${NAMESPACE}" \
		-H 'Content-Type: application/yaml' \
		--data-binary "@${f}" || true)"
	case "$code" in
		200 | 202) ;;
		*)
			fail "the ruler rejected $(basename "$f") with '${code}'." \
				"check the file is a valid Prometheus rule group; run 'scripts/rules.provision.sh --list' to see what is loaded." \
				"re-run 'scripts/rules.provision.sh' once the file is accepted."
			;;
	esac
done

loaded="$(curl -s --max-time 15 "${base_url}/prometheus/config/v1/rules" | grep -c 'record:' || true)"
pass "${#files[@]} rule file(s) uploaded; ${loaded} recording rule(s) now loaded."
info "the recorded series appear within one evaluation interval; query 'agent:cost_usd:sum' to confirm."

#!/usr/bin/env bash
#
# stack.up.sh
#
# @agents-index Bring-up wrapper that starts the stack and blocks until every readiness endpoint answers or a timeout elapses, and names the port fix on a bind failure.
#
# Purpose: start the stack and block until it is ready, so a script or an agent
# can depend on a ready stack rather than sleeping a guessed number of seconds.
# The script runs 'docker compose up -d', then polls the six readiness endpoints
# through the single loopback port until all answer or the timeout elapses. On a
# bind failure, the most likely first-run failure because another process may
# hold the port, it detects that cause and prints the fix naming EDGE_PORT and
# .env, rather than leaving a raw container runtime error.
#
# Usage:
#   scripts/stack.up.sh              Start the stack and wait up to 120 seconds.
#   scripts/stack.up.sh 180          Start the stack and wait up to 180 seconds.
#   scripts/stack.up.sh -h           Print this usage and exit 0.
#
# Parameters:
#   TIMEOUT   Optional. Whole seconds to wait for readiness. Default 120.
#   -h, --help  Print usage and exit 0.
#
# Environment:
#   EDGE_PORT   Loopback host port the edge proxy publishes. Read from the shell
#               first, then from .env, then defaults to 24317.

set -euo pipefail

# --- Location ----------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

timeout_seconds=120
case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
			timeout_seconds="$1"
		else
			echo "up: FAIL invalid timeout '$1'." >&2
			echo "  Fix: pass a whole number of seconds greater than zero, or no argument for the default of 120." >&2
			echo "  After: re-run 'scripts/stack.up.sh $timeout_seconds' with a valid timeout." >&2
			exit 2
		fi
		;;
esac

cd "$repo_root"

# --- Port resolution ---------------------------------------------------------
# The shell environment wins, then .env, then the default, matching how docker
# compose resolves EDGE_PORT. Only the EDGE_PORT line is read from .env, so no
# other value in that file is touched.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://127.0.0.1:${edge_port}"

# --- Start the stack ---------------------------------------------------------
# Capture the compose output so a bind failure can be recognised and answered
# with a fix, while the same output is streamed to the terminal and kept in a
# log file for later inspection.
compose_log="$(mktemp "${TMPDIR:-/tmp}/stack.up.XXXXXX")"
echo "up: starting the stack on port ${edge_port} (compose log: ${compose_log})"

if ! docker compose up -d 2>&1 | tee "$compose_log"; then
	if grep -qiE 'address already in use|already allocated|bind for|failed to bind|ports are not available' "$compose_log"; then
		echo "up: FAIL the host port ${edge_port} is already in use, so the edge proxy cannot bind it." >&2
		echo "  Fix: free the port, or set EDGE_PORT to a free port in a .env file at the repository root, for example 'EDGE_PORT=34317', then re-run this script. Copy .env.example to .env if you have no .env yet." >&2
		echo "  After: run 'scripts/stack.verify.sh' and confirm the single published port is the value you set." >&2
	else
		echo "up: FAIL 'docker compose up -d' did not start the stack (see ${compose_log})." >&2
		echo "  Fix: read the compose output above, resolve the reported cause, then re-run this script." >&2
		echo "  After: run 'scripts/stack.verify.sh' and confirm every check passes." >&2
	fi
	exit 1
fi

# --- Wait for readiness ------------------------------------------------------
# Poll every readiness endpoint through the single port until all answer 200 or
# the timeout elapses. On timeout, name the endpoint that did not answer and the
# backend that owns it.
pairs=(
	"/loki/ready|loki"
	"/prometheus/ready|mimir"
	"/tempo/ready|tempo"
	"/alloy/-/healthy|alloy"
	"/api/health|grafana"
	"/mlflow/health|mlflow"
)

http_status() {
	local path="$1"
	curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${base_url}${path}" || true
}

deadline=$((SECONDS + timeout_seconds))
echo "up: waiting up to ${timeout_seconds}s for readiness on ${base_url}"

while true; do
	pending_path=""
	pending_service=""
	for pair in "${pairs[@]}"; do
		path="${pair%%|*}"
		service="${pair##*|}"
		if [ "$(http_status "$path")" != "200" ]; then
			pending_path="$path"
			pending_service="$service"
			break
		fi
	done

	if [ -z "$pending_path" ]; then
		# Load the recording rules now that the ruler answers. They turn the
		# short-lived per-session counters into continuous series, without which
		# Grafana's Metrics Drilldown renders the whole stack as "No data" and a
		# newcomer concludes nothing is being collected. Provisioning here means a
		# fresh clone gets them without anyone knowing to ask.
		#
		# A failure is reported and does not stop the stack: the dashboard reads
		# the raw counters directly and works either way, so a ruler problem must
		# not make a healthy stack look broken.
		if [ -x "${script_dir}/rules.provision.sh" ]; then
			if ! "${script_dir}/rules.provision.sh" >/dev/null 2>&1; then
				echo "up: WARN the recording rules did not load; exploration views may show 'No data'."
				echo "     Run 'scripts/rules.provision.sh' to see why. The dashboard is unaffected."
			fi
		fi
		echo "up: PASS the stack is ready on ${base_url}"
		exit 0
	fi

	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "up: FAIL endpoint '${pending_path}' did not answer within ${timeout_seconds}s." >&2
		echo "  Fix: check the '${pending_service}' backend with 'docker compose logs ${pending_service}', or raise the timeout, for example 'scripts/stack.up.sh 240'." >&2
		echo "  After: run 'scripts/stack.verify.sh' and confirm '${pending_path}' returns 200." >&2
		exit 1
	fi

	sleep 2
done

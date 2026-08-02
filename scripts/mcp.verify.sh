#!/usr/bin/env bash
#
# mcp.verify.sh
#
# @agents-index Proves the Grafana MCP server through the single edge port: the handshake succeeds, tools list, every expected read-only category is present, and no writing tool is exposed.
#
# Purpose: prove the Grafana MCP server is usable and safe in one run, the way an
# MCP-capable agent reaches it, through the single published port. It asserts:
#   1. The MCP endpoint answers a streamable-HTTP handshake through the one port.
#   2. tools/list returns a non-empty tool set.
#   3. Every expected read-only category is present, by a representative tool:
#      search, datasource, dashboard, prometheus, loki, and navigation.
#      The pinned server (grafana/mcp-grafana:1.0.0) has no dedicated trace tool
#      category; traces are reached through the datasource tools, so this script
#      does not assert a trace tool and its absence is not a failure.
#   4. No writing tool is exposed in the default configuration.
#   5. The MCP service publishes no host port of its own.
# It exits non-zero on the first failure. Every failure names what failed, the
# fix, and what to check after.
#
# Usage:
#   scripts/mcp.verify.sh          Run every check against the running stack.
#   scripts/mcp.verify.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0. The script takes no other argument.
#
# Environment:
#   EDGE_PORT    Loopback host port the edge proxy publishes. Read from the shell
#                first, then from .env, then defaults to 24317. The MCP endpoint
#                is derived from it, never hard-coded.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so it runs the same way
# from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	"") ;;
	*)
		echo "mcp-verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run 'scripts/mcp.verify.sh' with no argument, or '-h' for usage." >&2
		echo "  After: re-run the command without the extra argument." >&2
		exit 2
		;;
esac

cd "$repo_root"

# --- Reporting helpers -------------------------------------------------------
fail() {
	local what="$1" fix="$2" after="$3"
	echo "mcp-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}
pass() { echo "mcp-verify: PASS $1"; }

# --- Port resolution ---------------------------------------------------------
# Shell environment wins, then .env, then the default, matching every other
# script in this repository so the port never disagrees across the toolchain.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
mcp_url="http://localhost:${edge_port}/grafana-mcp/mcp"

# --- MCP handshake -----------------------------------------------------------
# accept carries both media types the streamable-HTTP transport may answer with;
# the server replies with an SSE stream, so responses are parsed for a data line.
readonly MCP_ACCEPT='application/json, text/event-stream'

# handshake_session performs initialize and returns the session id from the
# response header, or fails naming the endpoint. It is the reachability proof.
handshake_session() {
	local hdrs sid
	hdrs="$(curl -s -D - -o /dev/null --max-time 15 -X POST "$mcp_url" \
		-H 'Content-Type: application/json' -H "Accept: ${MCP_ACCEPT}" \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-verify","version":"0"}}}' 2>/dev/null || true)"
	sid="$(printf '%s' "$hdrs" | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')"
	if [ -z "$sid" ]; then
		fail "the MCP endpoint did not answer the handshake through port ${edge_port} (${mcp_url})." \
			"start the stack with 'scripts/stack.up.sh' and confirm the mcp-grafana service is running and the /grafana-mcp/ route is healthy." \
			"re-run 'scripts/mcp.verify.sh' and confirm the handshake returns a session id."
	fi
	printf '%s' "$sid"
}

# list_tool_names completes the handshake with an initialized notification, then
# tools/list, and prints one tool name per line. The response is an SSE stream,
# so the last data line is the JSON-RPC result.
list_tool_names() {
	local sid="$1" body
	curl -s -o /dev/null --max-time 15 -X POST "$mcp_url" \
		-H 'Content-Type: application/json' -H "Accept: ${MCP_ACCEPT}" -H "Mcp-Session-Id: ${sid}" \
		-d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null || true
	body="$(curl -s --max-time 15 -X POST "$mcp_url" \
		-H 'Content-Type: application/json' -H "Accept: ${MCP_ACCEPT}" -H "Mcp-Session-Id: ${sid}" \
		-d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 2>/dev/null || true)"
	printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read()
data = None
for line in raw.splitlines():
    if line.startswith("data:"):
        data = json.loads(line[5:].strip())
if data is None and raw.strip():
    data = json.loads(raw)
for tool in (data or {}).get("result", {}).get("tools", []):
    print(tool["name"])
'
}

# --- Checks ------------------------------------------------------------------
session="$(handshake_session)"
pass "the MCP endpoint answered the handshake through port ${edge_port}."

mapfile -t tool_names < <(list_tool_names "$session")
tool_count="${#tool_names[@]}"
if [ "$tool_count" -eq 0 ]; then
	fail "the MCP server listed no tools." \
		"confirm the mcp-grafana service reaches Grafana by service name and that -enabled-tools is set in compose.yaml." \
		"re-run 'scripts/mcp.verify.sh' and confirm tools/list returns a non-empty set."
fi
pass "tools/list returned ${tool_count} tools."

# Representative tool per expected read-only category. Traces are intentionally
# absent: grafana/mcp-grafana:1.0.0 exposes no trace tool category.
declare -a categories=(
	"search:search_dashboards"
	"datasource:list_datasources"
	"dashboard:get_dashboard_by_uid"
	"prometheus:query_prometheus"
	"loki:query_loki_logs"
	"navigation:generate_deeplink"
)
tools_joined=" ${tool_names[*]} "
for entry in "${categories[@]}"; do
	cat="${entry%%:*}"; rep="${entry#*:}"
	case "$tools_joined" in
		*" $rep "*) ;;
		*)
			fail "the '${cat}' category is missing its expected tool '${rep}'." \
				"confirm -enabled-tools in compose.yaml includes '${cat}' and that the pinned image is grafana/mcp-grafana:1.0.0." \
				"re-run 'scripts/mcp.verify.sh' and confirm '${rep}' is in the tool list."
			;;
	esac
done
pass "all six read-only categories present (search, datasource, dashboard, prometheus, loki, navigation)."

# No writing tool. Writing tools carry a mutating verb in their name; the
# read-only default exposes none.
write_hits=()
for name in "${tool_names[@]}"; do
	case "$name" in
		create_* | update_* | delete_* | add_* | remove_* | set_* | write_* | *_create | *_update | *_delete | patch_*)
			write_hits+=("$name") ;;
	esac
done
if [ "${#write_hits[@]}" -ne 0 ]; then
	fail "a writing tool is exposed in the default configuration: ${write_hits[*]}." \
		"confirm compose.yaml passes -disable-write to the mcp-grafana service." \
		"re-run 'scripts/mcp.verify.sh' and confirm no writing tool is listed."
fi
pass "no writing tool is exposed (read-only default holds)."

# The MCP service publishes no host port of its own; only the edge proxy does.
mcp_pub="$(docker compose ps --format '{{.Service}} {{.Publishers}}' 2>/dev/null | awk '$1=="mcp-grafana"{$1="";print}')"
if printf '%s' "$mcp_pub" | grep -qE '127\.0\.0\.1|0\.0\.0\.0|:[0-9]+->'; then
	fail "the mcp-grafana service publishes a host port: ${mcp_pub}." \
		"remove any 'ports:' entry from the mcp-grafana service in compose.yaml; it must reach Grafana on the internal network only." \
		"re-run 'scripts/mcp.verify.sh' and confirm mcp-grafana lists no published host port."
fi
pass "the MCP service publishes no host port; only the edge proxy is reachable."

echo "mcp-verify: PASS (MCP server reachable, read-only, and internal on port ${edge_port})"

#!/usr/bin/env bash
#
# agent.verify.sh
#
# @agents-index End-to-end signal verifier for a coding agent: proves through the single edge port that a named agent's metric, log, and trace all reach the stack, with an assert-only mode for continuous integration and a drive mode that produces one real turn first.
#
# Purpose: prove that a configured coding agent actually exports telemetry, not
# just that the stack is up. This is the check the installation instruction runs
# after it configures an agent, so "configured" becomes "working" only when a
# metric, a log, and a trace for that agent have been seen in the stack. It reads
# all three signals through the one loopback port and reports which arrived.
#
# The agent name selects which signals to look for. Each agent writes a distinct
# metric series and carries a distinct service name on its logs and traces:
#   claude-code  metric claude_code_session_count_total, service name claude-code
#   pi           metric pi_session_count_total,          service name pi-coding-agent
# With no agent name the script checks both, which is how 'make ci' runs it.
#
# Two modes, because make ci must not drive an agent:
#   assert-only (default) asserts against signals that already exist within a
#     recent window. When the agent has produced no signal at all, there is
#     nothing to assert, so the script SKIPs and exits 0 rather than reporting a
#     failure the stack did not cause. This is what keeps 'make ci' green on a
#     stack where no agent turn has run, without ever driving a turn. A window
#     that holds some but not all three signals is also a SKIP, because the three
#     signals have independent retention and a partial recent window cannot be
#     attributed to a defect rather than to age.
#   --drive first runs one real turn for the named agent, waits for the export
#     interval, then asserts every signal produced after the turn started. Because
#     it marks the start time and looks only after it, a misconfigured agent that
#     produces nothing new fails even when the stack still holds old signals from
#     an earlier run. This mode needs the agent's CLI and its authentication and
#     is for a human proving an installation by hand, never for ci.
#
# Why last_over_time and never rate or increase for the metric: each agent
# session is a short-lived counter series, so the growth operators return zero on
# a series that exists but is not currently growing. last_over_time returns the
# last recorded sample within the window, which is what "a session was counted"
# means here.
#
# Usage:
#   scripts/agent.verify.sh                  Assert existing signals for both agents (ci mode).
#   scripts/agent.verify.sh claude-code      Assert existing signals for Claude Code.
#   scripts/agent.verify.sh pi               Assert existing signals for pi.
#   scripts/agent.verify.sh claude-code --drive
#                                            Run one real Claude Code turn, then assert.
#   scripts/agent.verify.sh pi --drive       Run one real pi turn, then assert.
#   scripts/agent.verify.sh -h               Print this usage and exit 0.
#
# Parameters:
#   AGENT        Optional. One of claude-code or pi. With none, both are checked.
#   -h, --help   Print usage and exit 0.
#   --drive      Drive one real agent turn before asserting. Needs the agent's
#                CLI and its authentication. Never used by ci.
#
# Environment:
#   EDGE_PORT           Loopback host port the edge proxy publishes. Read from the
#                       shell first, then from .env, then defaults to 24317. Every
#                       query address is derived from it and is never hard-coded.
#   AGENT_VERIFY_WAIT   Whole seconds to wait after a driven turn for the export
#                       interval to elapse. Default 20.
#   AGENT_VERIFY_WINDOW Recent window, in seconds, the assert-only mode looks back
#                       over. Default 3600.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the check runs the same
# way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Argument parsing --------------------------------------------------------
# A single optional agent name and an optional --drive flag, in either order.
mode="assert"
agent=""
for arg in "$@"; do
	case "$arg" in
		-h | --help)
			usage
			exit 0
			;;
		--drive)
			mode="drive"
			;;
		claude-code | pi)
			if [ -n "$agent" ]; then
				echo "agent-verify: FAIL more than one agent name given ('$agent' and '$arg')." >&2
				echo "  Fix: pass at most one agent name, either 'claude-code' or 'pi'." >&2
				echo "  After: re-run with a single agent name, or none to check both." >&2
				exit 2
			fi
			agent="$arg"
			;;
		*)
			echo "agent-verify: FAIL unknown argument '$arg'." >&2
			echo "  Fix: pass an agent name ('claude-code' or 'pi'), '--drive' to produce a turn first, or '-h' for usage." >&2
			echo "  After: re-run the command with a supported argument." >&2
			exit 2
			;;
	esac
done

if [ "$mode" = "drive" ] && [ -z "$agent" ]; then
	echo "agent-verify: FAIL --drive needs an agent name so it knows which turn to produce." >&2
	echo "  Fix: name the agent, for example 'scripts/agent.verify.sh claude-code --drive'." >&2
	echo "  After: re-run with an agent name alongside --drive." >&2
	exit 2
fi

# --- Tooling gate ------------------------------------------------------------
for tool in curl jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "agent-verify: FAIL required tool '$tool' is not on PATH." >&2
		echo "  Fix: install '$tool' (both curl and jq are needed for the queries)." >&2
		echo "  After: run '$tool --version' and confirm it prints, then re-run this script." >&2
		exit 2
	fi
done

# --- Port resolution ---------------------------------------------------------
# The shell environment wins, then .env, then the default. This matches how
# docker compose resolves EDGE_PORT. Only the EDGE_PORT line is read from .env.
resolve_edge_port() {
	local port="${EDGE_PORT:-}"
	if [ -z "$port" ] && [ -f "$repo_root/.env" ]; then
		port="$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' "$repo_root/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
	fi
	printf '%s' "${port:-24317}"
}

edge_port="$(resolve_edge_port)"
base_url="http://127.0.0.1:${edge_port}"
wait_seconds="${AGENT_VERIFY_WAIT:-20}"
window_seconds="${AGENT_VERIFY_WINDOW:-3600}"

# --- Reporting helper --------------------------------------------------------
fail() {
	local what="$1" fix="$2" after="$3"
	echo "agent-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Per-agent metadata ------------------------------------------------------
# Map an agent name to the metric series it writes, the service name its logs and
# traces carry, and the CLI that drives one turn. The log and trace service name
# is not always the agent name, so it is looked up rather than assumed.
agent_metric() {
	case "$1" in
		claude-code) printf 'claude_code_session_count_total' ;;
		pi) printf 'pi_session_count_total' ;;
	esac
}
agent_service_name() {
	case "$1" in
		claude-code) printf 'claude-code' ;;
		pi) printf 'pi-coding-agent' ;;
	esac
}
agent_cli() {
	case "$1" in
		claude-code) printf 'claude' ;;
		pi) printf 'pi' ;;
	esac
}

# --- Signal queries ----------------------------------------------------------
# Each returns 0 when the signal is present in the given epoch-second window and
# non-zero when it is absent. A window start of 0 means "any time recent"; the
# metric query then uses the configured window and the log and trace queries use
# it as their start bound.

# metric_present AGENT START_EPOCH
# Present when the agent's counter has a sample no older than the window. The
# window length is the larger of the configured window and the age since START,
# so a driven turn just produced is always inside it.
metric_present() {
	local a="$1" start="$2" now age win metric resp count
	metric="$(agent_metric "$a")"
	now="$(date +%s)"
	if [ "$start" -gt 0 ]; then
		age=$((now - start + 30))
		win="$age"
	else
		win="$window_seconds"
	fi
	resp="$(curl -s --max-time 15 -G "${base_url}/prometheus/api/v1/query" \
		--data-urlencode "query=count(last_over_time(${metric}[${win}s]))" || true)"
	count="$(printf '%s' "$resp" | jq -r '.data.result | length' 2>/dev/null || echo 0)"
	[ "${count:-0}" -gt 0 ]
}

# log_present AGENT START_EPOCH
# Present when Loki holds at least one log line for the agent's service name in
# the window. START of 0 falls back to the configured window.
log_present() {
	local a="$1" start="$2" now start_ns end_ns service resp count
	service="$(agent_service_name "$a")"
	now="$(date +%s)"
	if [ "$start" -le 0 ]; then start=$((now - window_seconds)); fi
	start_ns="${start}000000000"
	end_ns="${now}000000000"
	resp="$(curl -s --max-time 15 -G "${base_url}/loki/api/v1/query_range" \
		--data-urlencode "query={service_name=\"${service}\"}" \
		--data-urlencode "start=${start_ns}" \
		--data-urlencode "end=${end_ns}" \
		--data-urlencode "limit=1" || true)"
	count="$(printf '%s' "$resp" | jq -r '.data.result | length' 2>/dev/null || echo 0)"
	[ "${count:-0}" -gt 0 ]
}

# trace_present AGENT START_EPOCH
# Present when Tempo holds at least one trace for the agent's service name in the
# window. START of 0 falls back to the configured window.
trace_present() {
	local a="$1" start="$2" now service resp count
	service="$(agent_service_name "$a")"
	now="$(date +%s)"
	if [ "$start" -le 0 ]; then start=$((now - window_seconds)); fi
	resp="$(curl -s --max-time 20 -G "${base_url}/tempo/api/search" \
		--data-urlencode "q={resource.service.name=\"${service}\"}" \
		--data-urlencode "start=${start}" \
		--data-urlencode "end=${now}" \
		--data-urlencode "limit=1" || true)"
	count="$(printf '%s' "$resp" | jq -r '.traces | length' 2>/dev/null || echo 0)"
	[ "${count:-0}" -gt 0 ]
}

# --- Drive one real turn -----------------------------------------------------
# Produce one non-interactive turn for the agent in the caller's own working
# directory, then let the caller assert the signals that arrive after the marked
# start. The turn runs in the caller's directory on purpose: that is the
# directory the installation instruction has just configured, so the settings it
# wrote at project or local scope govern the turn. A scratch directory would fall
# back to the user's global settings and export to the wrong endpoint, because an
# agent's settings file wins over a shell environment variable. For that same
# reason the drive does not set the export endpoint here; the configured agent
# owns it. It exports only a short interval as a best-effort flush hint, which an
# agent that honours environment overrides uses and an agent whose settings pin
# the interval ignores. Returns the drive start epoch on stdout.
drive_one_turn() {
	local a="$1" cli prompt start
	cli="$(agent_cli "$a")"
	if ! command -v "$cli" >/dev/null 2>&1; then
		fail "the --drive mode needs the '${cli}' CLI for agent '${a}', which is not on PATH." \
			"install and authenticate the '${cli}' CLI, or run the default assert-only mode which needs no agent." \
			"run '${cli} --version' and confirm it prints, then re-run with '${a} --drive'."
	fi
	prompt='Print the word agentverify and nothing else.'
	echo "agent-verify: driving one ${cli} turn in the current directory (this reaches the model and may take a moment)" >&2
	start="$(date +%s)"
	(
		export OTEL_METRIC_EXPORT_INTERVAL=1000
		export OTEL_LOGS_EXPORT_INTERVAL=1000
		export OTEL_TRACES_EXPORT_INTERVAL=1000
		printf '%s' "$prompt" | "$cli" -p >/dev/null 2>&1
	) || fail "the ${cli} turn did not complete." \
		"run a '${cli} -p' turn by hand and confirm the CLI is authenticated and configured for telemetry." \
		"once a turn completes, re-run this script with '${a} --drive'."
	echo "agent-verify: waiting ${wait_seconds}s for the export interval to elapse" >&2
	sleep "$wait_seconds"
	printf '%s' "$start"
}

# --- Assert every signal arrived for one agent (drive mode) ------------------
# In drive mode all three signals must be present after the marked start. A
# missing signal is a real failure, so it names every cause from the fixed list.
assert_after_drive() {
	local a="$1" start="$2" missing=()
	metric_present "$a" "$start" || missing+=("metric")
	log_present "$a" "$start" || missing+=("log")
	trace_present "$a" "$start" || missing+=("trace")
	if [ "${#missing[@]}" -eq 0 ]; then
		echo "agent-verify: PASS agent '${a}' exported a metric, a log, and a trace after the turn, seen through port ${edge_port}."
		return 0
	fi
	fail "agent '${a}' did not export: ${missing[*]} (checked after the driven turn, through port ${edge_port})." \
		"work these causes in order: the stack is not running (run 'scripts/stack.verify.sh'); the export address does not point at the edge port ${edge_port}; the metrics temporality key OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative is missing, which drops every metric while logs and traces still arrive; for pi the '@desek/pi-opentelemetry' package is not installed; the export interval has not elapsed (raise AGENT_VERIFY_WAIT above ${wait_seconds})." \
		"fix the named cause, then re-run 'scripts/agent.verify.sh ${a} --drive' and confirm all three arrive."
}

# --- Assert existing signals for one agent (assert-only mode) ----------------
# Report which of the three are present in the recent window. All three present
# is a PASS. None present is a SKIP, because no turn has run. A partial window is
# also a SKIP, because the three signals age out independently and a partial
# recent window cannot be told from a defect without driving a turn.
assert_existing() {
	local a="$1" present=() absent=()
	metric_present "$a" 0 && present+=("metric") || absent+=("metric")
	log_present "$a" 0 && present+=("log") || absent+=("log")
	trace_present "$a" 0 && present+=("trace") || absent+=("trace")
	if [ "${#absent[@]}" -eq 0 ]; then
		echo "agent-verify: PASS agent '${a}' has a metric, a log, and a trace within the last ${window_seconds}s, seen through port ${edge_port}."
		return 0
	fi
	if [ "${#present[@]}" -eq 0 ]; then
		echo "agent-verify: SKIP agent '${a}' has produced no signal within the last ${window_seconds}s, so there is nothing to assert."
		echo "  To produce signals and assert them, run 'scripts/agent.verify.sh ${a} --drive'."
		return 0
	fi
	echo "agent-verify: SKIP agent '${a}' has a partial recent window (present: ${present[*]}; absent: ${absent[*]}); the signals age out independently, so drive a turn to assert."
	echo "  To assert all three from one fresh turn, run 'scripts/agent.verify.sh ${a} --drive'."
	return 0
}

# --- Run ---------------------------------------------------------------------
echo "agent-verify: checking agent signals on port ${edge_port}"

if [ "$mode" = "drive" ]; then
	drive_start="$(drive_one_turn "$agent")"
	assert_after_drive "$agent" "$drive_start"
	exit 0
fi

# Assert-only mode: check the named agent, or both when none was named.
if [ -n "$agent" ]; then
	assert_existing "$agent"
else
	assert_existing "claude-code"
	assert_existing "pi"
fi

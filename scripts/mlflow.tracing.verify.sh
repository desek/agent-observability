#!/usr/bin/env bash
#
# mlflow.tracing.verify.sh
#
# @agents-index Verifier for the Claude Code conversation-tracing integration: asserts through the single edge port that a trace in the agent experiment carries both the user turn and the assistant turn, with an assert-only mode for continuous integration and a drive mode that produces a real turn first.
#
# Purpose: prove the agent integration produced a browsable conversation trace,
# not just that the tracking server is up. It reads the agent experiment through
# the one loopback port, searches its traces, and asserts a trace carries the
# user turn and the assistant turn, the two halves that make a trace a
# conversation. A trace's request preview is the user turn and its response
# preview is the assistant turn, so a trace with both non-empty is a conversation
# and not a bare span.
#
# Two modes, because make ci must not drive an agent:
#   assert-only (default) asserts against traces that already exist. When the
#     agent experiment holds no trace yet, there is nothing to assert, so the
#     script SKIPs and exits 0 rather than reporting a failure the stack did not
#     cause. This is what lets it run in 'make ci' on a stack where no turn has
#     been recorded, without ever requiring an agent turn or a network fetch.
#   --drive first runs one real Claude Code turn with tracing enabled in a scratch
#     directory, then asserts. This mode needs the 'claude' CLI and its
#     authentication and is for a human proving the integration by hand, never for
#     ci.
#   --survives-stopped is the NFR2 and AC-13 proof: with the tracking server
#     unreachable, one real Claude Code turn with tracing enabled must still
#     complete normally and surface no error. The mode refuses to run unless the
#     server is actually down (so it cannot pass by accident against a live
#     server), enables tracing in a scratch directory, drives a turn, and asserts
#     the turn produced its expected output and exited cleanly. It writes no trace
#     assertion, because the point is that a failed trace write never reaches the
#     user. Like --drive it needs the 'claude' CLI and is never used by ci.
#
# Why the version 3 endpoint: MLflow 3 stores traces under a location, so the
# working search is POST api/3.0/mlflow/traces/search with a 'locations' list
# naming the experiment. The 2.0 traces/search path returns 405, and the 3.0 path
# without 'locations' returns 400, so both are dead ends and the location form is
# the only one that answers.
#
# Usage:
#   scripts/mlflow.tracing.verify.sh          Assert against existing traces (ci mode).
#   scripts/mlflow.tracing.verify.sh --drive  Run one real Claude Code turn, then assert.
#   scripts/mlflow.tracing.verify.sh --survives-stopped
#                                             With the tracking server stopped, run one
#                                             real turn and assert it completes normally.
#   scripts/mlflow.tracing.verify.sh -h       Print this usage and exit 0.
#
# Parameters:
#   -h, --help   Print usage and exit 0.
#   --drive      Drive one real agent turn before asserting. Needs the claude CLI
#                and its authentication. Never used by ci.
#   --survives-stopped
#                Prove NFR2 and AC-13: with the tracking server unreachable, one
#                real turn still completes and surfaces no error. Refuses to run
#                against a reachable server. Needs the claude CLI. Never used by ci.
#
# Environment:
#   EDGE_PORT    Loopback host port the edge proxy publishes. Read from the shell
#                first, then from .env, then defaults to 24317. The MLflow address
#                is derived from it and is never hard-coded.
#   MLFLOW_TRACING_EXPERIMENT
#                Agent experiment to check. Default claude-code.

set -euo pipefail

# --- Location ----------------------------------------------------------------
# Resolve the repository root from the script location so the check runs the same
# way from any working directory.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
	sed -n '3,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

mode="assert"
case "${1:-}" in
	-h | --help)
		usage
		exit 0
		;;
	--drive)
		mode="drive"
		;;
	--survives-stopped)
		mode="survives-stopped"
		;;
	"") ;;
	*)
		echo "tracing-verify: FAIL unknown argument '$1'." >&2
		echo "  Fix: run with no argument for assert-only, '--drive' to produce a turn first, '--survives-stopped' to prove a turn survives a stopped server, or '-h' for usage." >&2
		echo "  After: re-run the command with a supported argument." >&2
		exit 2
		;;
esac

# --- Tooling gate ------------------------------------------------------------
for tool in curl jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "tracing-verify: FAIL required tool '$tool' is not on PATH." >&2
		echo "  Fix: install '$tool' (both curl and jq are needed), or run this inside the pinned mlflow image which ships them." >&2
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
mlflow_url="http://127.0.0.1:${edge_port}/mlflow"
experiment_name="${MLFLOW_TRACING_EXPERIMENT:-claude-code}"

# --- Reporting helper --------------------------------------------------------
fail() {
	local what="$1" fix="$2" after="$3"
	echo "tracing-verify: FAIL $what" >&2
	echo "  Fix: $fix" >&2
	echo "  After: $after" >&2
	exit 1
}

# --- Resolve the agent experiment id -----------------------------------------
# The trace search names the experiment by id, so resolve the id from the name
# first. A missing experiment is a provisioning failure, not an empty result, so
# it fails rather than skips.
resolve_experiment_id() {
	local resp
	resp="$(curl -s --max-time 15 \
		"${mlflow_url}/api/2.0/mlflow/experiments/get-by-name?experiment_name=${experiment_name}" || true)"
	printf '%s' "$resp" | jq -r '.experiment.experiment_id // empty'
}

# --- Search the experiment's traces via the version 3 location form ----------
# Prints the raw JSON body of the search response. The location form is the only
# one the server answers; see the header note on the 405 and 400 dead ends.
search_traces() {
	local experiment_id="$1"
	curl -s --max-time 15 "${mlflow_url}/api/3.0/mlflow/traces/search" \
		-H 'Content-Type: application/json' \
		-d "{\"locations\":[{\"type\":\"MLFLOW_EXPERIMENT\",\"mlflow_experiment\":{\"experiment_id\":\"${experiment_id}\"}}],\"max_results\":10}"
}

# --- Optional: drive one real Claude Code turn -------------------------------
# Enables tracing in a fresh scratch directory through the project's own enable
# script, runs one 'claude' turn there, and cleans the scratch directory up. The
# scratch directory is created under the system temp area, never in this
# repository, so this repository's .claude directory is never touched.
drive_one_turn() {
	if ! command -v claude >/dev/null 2>&1; then
		fail "the --drive mode needs the 'claude' CLI, which is not on PATH." \
			"install the Claude Code CLI and authenticate it, or run the default assert-only mode which needs no agent." \
			"run 'claude --version' and confirm it prints, then re-run with '--drive'."
	fi
	local scratch
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/mlflow-tracing-verify.XXXXXX")"
	# Remove the scratch directory on return, whatever the outcome.
	trap 'rm -rf "$scratch"' RETURN
	echo "tracing-verify: enabling tracing in scratch directory ${scratch}"
	EDGE_PORT="$edge_port" "$script_dir/mlflow.autolog.claude.sh" --yes -d "$scratch" \
		|| fail "enabling tracing in the scratch directory failed." \
			"run 'scripts/mlflow.autolog.claude.sh --yes -d ${scratch}' by hand and read its failure message." \
			"fix the cause it names, then re-run this script with '--drive'."
	echo "tracing-verify: driving one claude turn (this reaches the model and may take a moment)"
	( cd "$scratch" && printf 'Print the word mlflowtrace and nothing else.' \
		| claude -p >/dev/null 2>&1 ) \
		|| fail "the claude turn did not complete in the scratch directory." \
			"run a 'claude -p' turn by hand and confirm the CLI is authenticated ('claude /status')." \
			"once a turn completes, re-run this script with '--drive'."
	# The plugin runtime writes the trace after the turn ends; give it a moment.
	sleep 3
}

# --- Prove a turn survives a stopped tracking server (NFR2, AC-13) ------------
# With the tracking server unreachable, one real turn with tracing enabled must
# still complete and surface no error, because the plugin runtime writes the
# trace after the turn ends and a failed write must never reach the user. The
# mode refuses to run against a reachable server, so it cannot pass by accident;
# the operator stops the server first (for this stack:
# 'docker compose -p agent-observability stop mlflow', restored with 'start').
prove_survives_stopped() {
	if ! command -v claude >/dev/null 2>&1; then
		fail "the --survives-stopped mode needs the 'claude' CLI, which is not on PATH." \
			"install the Claude Code CLI and authenticate it." \
			"run 'claude --version' and confirm it prints, then re-run with '--survives-stopped'."
	fi
	# Refuse unless the server is genuinely unreachable, so a live server cannot
	# make this pass silently. A reachable /health returns HTTP 200.
	local health_code
	health_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${mlflow_url}/health" || true)"
	if [ "$health_code" = "200" ]; then
		fail "the tracking server at ${mlflow_url} is still reachable (health ${health_code}); this mode needs it stopped." \
			"stop the tracking server first, for this stack 'docker compose -p agent-observability stop mlflow', then re-run. Restore it afterwards with 'docker compose -p agent-observability start mlflow'." \
			"confirm 'curl -s -o /dev/null -w %{http_code} ${mlflow_url}/health' does not return 200, then re-run with '--survives-stopped'."
	fi
	echo "tracing-verify: server at ${mlflow_url} is unreachable (health '${health_code:-none}'), as this mode requires."
	local scratch
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/mlflow-tracing-survives.XXXXXX")"
	trap 'rm -rf "$scratch"' RETURN
	# Enable tracing in the scratch directory. Enable only writes settings through
	# the client and does not need the tracking server, so it succeeds while the
	# server is down.
	echo "tracing-verify: enabling tracing in scratch directory ${scratch}"
	EDGE_PORT="$edge_port" "$script_dir/mlflow.autolog.claude.sh" --yes -d "$scratch" >/dev/null \
		|| fail "enabling tracing in the scratch directory failed." \
			"run 'scripts/mlflow.autolog.claude.sh --yes -d ${scratch}' by hand and read its failure message." \
			"fix the cause it names, then re-run with '--survives-stopped'."
	echo "tracing-verify: driving one claude turn with the tracking server stopped"
	local turn_out turn_rc expected="survivestopped"
	# Disable errexit around the capture so a non-zero turn is inspected here
	# rather than aborting the script before the exit status is read.
	set +e
	turn_out="$(cd "$scratch" && printf 'Print the word survivestopped and nothing else.' | claude -p 2>&1)"
	turn_rc=$?
	set -e
	echo "tracing-verify: turn exit status ${turn_rc}; output: ${turn_out}"
	if [ "$turn_rc" -ne 0 ]; then
		fail "the claude turn did not complete cleanly with the server stopped (exit ${turn_rc})." \
			"NFR2 requires the turn to survive a tracking-server failure; if the turn itself failed, confirm the CLI is authenticated ('claude /status') and re-run." \
			"restore the server ('docker compose -p agent-observability start mlflow') and re-run."
	fi
	if ! printf '%s' "$turn_out" | grep -qi "$expected"; then
		fail "the turn completed but its output did not contain the expected word '${expected}' (got: ${turn_out})." \
			"the turn should answer normally even with tracing unable to write; inspect the output above." \
			"restore the server and re-run with '--survives-stopped'."
	fi
	echo "tracing-verify: PASS a turn completed normally (exit 0, expected output present) with the tracking server stopped; the failed trace write surfaced no error."
}

if [ "$mode" = "survives-stopped" ]; then
	prove_survives_stopped
	exit 0
fi

# --- Assert a trace carries both turns ----------------------------------------
echo "tracing-verify: checking experiment '${experiment_name}' at ${mlflow_url}"

experiment_id="$(resolve_experiment_id)"
if [ -z "$experiment_id" ]; then
	fail "the agent experiment '${experiment_name}' does not exist on the stack." \
		"provision it with 'scripts/mlflow.provision.sh'; a correctly provisioned stack has both 'claude-code' and 'pi'." \
		"re-run 'scripts/stack.verify.sh' to confirm provisioning, then re-run this script."
fi

if [ "$mode" = "drive" ]; then
	drive_one_turn
fi

search_resp="$(search_traces "$experiment_id" || true)"
trace_count="$(printf '%s' "$search_resp" | jq -r '.traces | length // 0' 2>/dev/null || echo 0)"

if [ "$mode" != "drive" ] && [ "${trace_count:-0}" -eq 0 ]; then
	# Assert-only mode with no recorded turn yet: nothing to assert. This is the
	# path that keeps make ci green on a stack where no agent turn has run. It is
	# a skip, not a claim that tracing works, so it never masks a real defect.
	echo "tracing-verify: SKIP experiment '${experiment_name}' holds no trace yet, so there is no conversation to assert."
	echo "  To produce one and assert it, run 'scripts/mlflow.tracing.verify.sh --drive', or enable tracing with 'scripts/mlflow.autolog.claude.sh' and take a turn."
	exit 0
fi

if [ "${trace_count:-0}" -eq 0 ]; then
	fail "no trace appeared in experiment '${experiment_name}' after driving a turn." \
		"confirm tracing enabled cleanly (re-run the enable step) and that the turn reached the model; the plugin runtime writes the trace only when a turn ends." \
		"re-run 'scripts/mlflow.tracing.verify.sh --drive' and confirm a trace is written."
fi

# Take the most recent trace and assert both halves of the conversation are
# present. The request preview is the user turn, the response preview is the
# assistant turn.
user_turn="$(printf '%s' "$search_resp" | jq -r '.traces[0].request_preview // empty')"
assistant_turn="$(printf '%s' "$search_resp" | jq -r '.traces[0].response_preview // empty')"
trace_id="$(printf '%s' "$search_resp" | jq -r '.traces[0].trace_id // "unknown"')"

if [ -z "$user_turn" ]; then
	fail "trace '${trace_id}' in experiment '${experiment_name}' carries no user turn (request preview is empty)." \
		"the transcript reached MLflow without the prompt; confirm the plugin captured the user message and check the mlflow backend log." \
		"drive a fresh turn with 'scripts/mlflow.tracing.verify.sh --drive' and confirm the request preview is non-empty."
fi
if [ -z "$assistant_turn" ]; then
	fail "trace '${trace_id}' in experiment '${experiment_name}' carries no assistant turn (response preview is empty)." \
		"the turn was recorded without a response; confirm the turn completed and the plugin captured the assistant message, and check the mlflow backend log." \
		"drive a fresh turn with 'scripts/mlflow.tracing.verify.sh --drive' and confirm the response preview is non-empty."
fi

echo "tracing-verify: PASS trace '${trace_id}' in experiment '${experiment_name}' carries the user turn and the assistant turn."
